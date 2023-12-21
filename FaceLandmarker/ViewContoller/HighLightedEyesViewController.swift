//
//  HighLightedEyesViewController.swift
//  FaceLandmarker
//
//  Created by Sachin Gupta on 12/14/23.
//

import AVFoundation
import MediaPipeTasksVision
import UIKit

/**
 * The view controller is responsible for performing detection on incoming frames from the live camera and presenting the frames with the
 * landmark of the landmarked faces to the user.
 */
class HighLightedEyesViewController: UIViewController {
  private struct Constants {
    static let edgeOffset: CGFloat = 2.0
  }
  
  weak var inferenceResultDeliveryDelegate: InferenceResultDeliveryDelegate?
  weak var interfaceUpdatesDelegate: InterfaceUpdatesDelegate?
  
  @IBOutlet weak var previewView: UIView!
  @IBOutlet weak var cameraUnavailableLabel: UILabel!
  @IBOutlet weak var resumeButton: UIButton!
  @IBOutlet weak var overlayView: NewOverlayView!
  
  private var isSessionRunning = false
  private var isObserving = false
  private let backgroundQueue = DispatchQueue(label: "com.google.mediapipe.cameraController.backgroundQueue")
  
  // MARK: Controllers that manage functionality
  // Handles all the camera related functionality
  private lazy var cameraFeedService = CameraFeedService(previewView: previewView)
  
  private let faceLandmarkerServiceQueue = DispatchQueue(
    label: "com.google.mediapipe.cameraController.faceLandmarkerServiceQueue",
    attributes: .concurrent)
  
  // Queuing reads and writes to faceLandmarkerService using the Apple recommended way
  // as they can be read and written from multiple threads and can result in race conditions.
  private var _faceLandmarkerService: FaceLandmarkerService?
  private var faceLandmarkerService: FaceLandmarkerService? {
    get {
      faceLandmarkerServiceQueue.sync {
        return self._faceLandmarkerService
      }
    }
    set {
      faceLandmarkerServiceQueue.async(flags: .barrier) {
        self._faceLandmarkerService = newValue
      }
    }
  }

#if !targetEnvironment(simulator)
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    initializeFaceLandmarkerServiceOnSessionResumption()
    cameraFeedService.startLiveCameraSession {[weak self] cameraConfiguration in
      DispatchQueue.main.async {
        switch cameraConfiguration {
        case .failed:
          self?.presentVideoConfigurationErrorAlert()
        case .permissionDenied:
          self?.presentCameraPermissionsDeniedAlert()
        default:
          break
        }
      }
    }
  }
  
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    cameraFeedService.stopSession()
    clearFaceLandmarkerServiceOnSessionInterruption()
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    cameraFeedService.delegate = self
      overlayView.previewView = previewView
    // Do any additional setup after loading the view.
  }
  
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    cameraFeedService.updateVideoPreviewLayer(toFrame: previewView.bounds)
  }
  
  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    cameraFeedService.updateVideoPreviewLayer(toFrame: previewView.bounds)
  }
#endif
  
  // Resume camera session when click button resume
  @IBAction func onClickResume(_ sender: Any) {
    cameraFeedService.resumeInterruptedSession {[weak self] isSessionRunning in
      if isSessionRunning {
        self?.resumeButton.isHidden = true
        self?.cameraUnavailableLabel.isHidden = true
        self?.initializeFaceLandmarkerServiceOnSessionResumption()
      }
    }
  }
  
  private func presentCameraPermissionsDeniedAlert() {
    let alertController = UIAlertController(
      title: "Camera Permissions Denied",
      message:
        "Camera permissions have been denied for this app. You can change this by going to Settings",
      preferredStyle: .alert)
    
    let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
    let settingsAction = UIAlertAction(title: "Settings", style: .default) { (action) in
      UIApplication.shared.open(
        URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
    }
    alertController.addAction(cancelAction)
    alertController.addAction(settingsAction)
    
    present(alertController, animated: true, completion: nil)
  }
  
  private func presentVideoConfigurationErrorAlert() {
    let alert = UIAlertController(
      title: "Camera Configuration Failed",
      message: "There was an error while configuring camera.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
    
    self.present(alert, animated: true)
  }
  
  private func initializeFaceLandmarkerServiceOnSessionResumption() {
    clearAndInitializeFaceLandmarkerService()
    startObserveConfigChanges()
  }
  
  @objc private func clearAndInitializeFaceLandmarkerService() {
    faceLandmarkerService = nil
    faceLandmarkerService = FaceLandmarkerService
      .liveStreamFaceLandmarkerService(
        modelPath: InferenceConfigurationManager.sharedInstance.modelPath,
        numFaces: InferenceConfigurationManager.sharedInstance.numFaces,
        minFaceDetectionConfidence: InferenceConfigurationManager.sharedInstance.minFaceDetectionConfidence,
        minFacePresenceConfidence: InferenceConfigurationManager.sharedInstance.minFacePresenceConfidence,
        minTrackingConfidence: InferenceConfigurationManager.sharedInstance.minTrackingConfidence,
        liveStreamDelegate: self)
  }
  
  private func clearFaceLandmarkerServiceOnSessionInterruption() {
    stopObserveConfigChanges()
    faceLandmarkerService = nil
  }
  
  private func startObserveConfigChanges() {
    NotificationCenter.default
      .addObserver(self,
                   selector: #selector(clearAndInitializeFaceLandmarkerService),
                   name: InferenceConfigurationManager.notificationName,
                   object: nil)
    isObserving = true
  }
  
  private func stopObserveConfigChanges() {
    if isObserving {
      NotificationCenter.default
        .removeObserver(self,
                        name:InferenceConfigurationManager.notificationName,
                        object: nil)
    }
    isObserving = false
  }
}

extension HighLightedEyesViewController: CameraFeedServiceDelegate {
  
  func didOutput(sampleBuffer: CMSampleBuffer, orientation: UIImage.Orientation) {
    let currentTimeMs = Date().timeIntervalSince1970 * 1000
    // Pass the pixel buffer to mediapipe
    backgroundQueue.async { [weak self] in
      self?.faceLandmarkerService?.detectAsync(
        sampleBuffer: sampleBuffer,
        orientation: orientation,
        timeStamps: Int(currentTimeMs))
    }
  }
  
  // MARK: Session Handling Alerts
  func sessionWasInterrupted(canResumeManually resumeManually: Bool) {
    // Updates the UI when session is interupted.
    if resumeManually {
      resumeButton.isHidden = false
    } else {
      cameraUnavailableLabel.isHidden = false
    }
    clearFaceLandmarkerServiceOnSessionInterruption()
  }
  
  func sessionInterruptionEnded() {
    // Updates UI once session interruption has ended.
    cameraUnavailableLabel.isHidden = true
    resumeButton.isHidden = true
    initializeFaceLandmarkerServiceOnSessionResumption()
  }
  
  func didEncounterSessionRuntimeError() {
    // Handles session run time error by updating the UI and providing a button if session can be
    // manually resumed.
    resumeButton.isHidden = false
    clearFaceLandmarkerServiceOnSessionInterruption()
  }
}

// MARK: FaceLandmarkerServiceLiveStreamDelegate
extension HighLightedEyesViewController: FaceLandmarkerServiceLiveStreamDelegate {

  func faceLandmarkerService(
    _ faceLandmarkerService: FaceLandmarkerService,
    didFinishDetection result: ResultBundle?,
    error: Error?) {
      DispatchQueue.main.async { [weak self] in
        guard let weakSelf = self else { return }
        weakSelf.inferenceResultDeliveryDelegate?.didPerformInference(result: result)
        guard let faceLandmarkerResult = result?.faceLandmarkerResults.first as? FaceLandmarkerResult else { return }
        let imageSize = weakSelf.cameraFeedService.videoResolution
        let faceOverlays = NewOverlayView.faceOverlays(
          fromMultipleFaceLandmarks: faceLandmarkerResult.faceLandmarks,
          inferredOnImageOfSize: imageSize,
          ovelayViewSize: weakSelf.overlayView.bounds.size,
          imageContentMode: weakSelf.overlayView.imageContentMode,
          andOrientation: UIImage.Orientation.from(
            deviceOrientation: UIDevice.current.orientation))
        weakSelf.overlayView.draw(faceOverlays: faceOverlays,
                         inBoundsOfContentImageOfSize: imageSize,
                         imageContentMode: weakSelf.cameraFeedService.videoGravity.contentMode)
      }
    }
}

// MARK: - AVLayerVideoGravity Extension
//extension BlackFaceAVLayerVideoGravity {
//  var contentMode: UIView.ContentMode {
//    switch self {
//    case .resizeAspectFill:
//      return .scaleAspectFill
//    case .resizeAspect:
//      return .scaleAspectFit
//    case .resize:
//      return .scaleToFill
//    default:
//      return .scaleAspectFill
//    }
//  }
//}

import UIKit
import MediaPipeTasksVision

///// A straight line.
//struct Line {
//  let from: CGPoint
//  let to: CGPoint
//}
//
///// Line connection
//struct LineConnection {
//  let color: UIColor
//  let lines: [Line]
//}
//
///**
// This structure holds the display parameters for the overlay to be drawon on a detected object.
// */
//struct FaceOverlay {
//  let dots: [CGPoint]
//  let lineConnections: [LineConnection]
//}

/// Custom view to visualize the face landmarker result on top of the input image.
class NewOverlayView: UIView {
  var previewView: UIView!
  var faceOverlays: [FaceOverlay] = []
  private let starLayer = CAShapeLayer()
  private let starLayer1 = CAShapeLayer()
  private var contentImageSize: CGSize = CGSizeZero
    var imageContentMode: UIView.ContentMode = .scaleAspectFill
  private var orientation = UIDeviceOrientation.portrait

  private var edgeOffset: CGFloat = 0.0

  // MARK: Public Functions
  func draw(
    faceOverlays: [FaceOverlay],
    inBoundsOfContentImageOfSize imageSize: CGSize,
    edgeOffset: CGFloat = 0.0,
    imageContentMode: UIView.ContentMode) {

     // self.clear()
      contentImageSize = imageSize
      self.edgeOffset = edgeOffset
      self.faceOverlays = faceOverlays
      self.imageContentMode = imageContentMode
      orientation = UIDevice.current.orientation
      self.setNeedsDisplay()
    }
    
    private func createStarLayer() {
        starLayer.fillColor = UIColor.green.cgColor
        starLayer.strokeColor = UIColor.red.cgColor
       // starLayer.frame = CGRect(origin: CGPoint(x: 300.5, y: 300.5), size: CGSize(width: 200, height: 200)) // Adjust size based on your needs
        starLayer1.fillColor = UIColor.yellow.cgColor
        starLayer1.strokeColor = UIColor.red.cgColor
        //starLayer1.frame = CGRect(origin: CGPoint(x: 100.5, y: 300.5), size: CGSize(width: 200, height: 200)) //
        //updateStarPath()
    }

 //   func drawLines(_ lines: [Line], lineColor: UIColor) {
//        let path = UIBezierPath()
//        for line in lines {
//          path.move(to: line.from)
//          path.addLine(to: line.to)
//        }
//        path.lineWidth = DefaultConstants.lineWidth
//        lineColor.setFill()
//        path.stroke()
//        let shapeLayer = CAShapeLayer()
//        shapeLayer.path = path.cgPath
//        layer.addSublayer(shapeLayer)
//        layer.mask = shapeLayer
//        layer.masksToBounds = true
//        layer.backgroundColor = UIColor.green.cgColor
//
//      }
  func redrawFaceOverlays(forNewDeviceOrientation deviceOrientation:UIDeviceOrientation) {

    orientation = deviceOrientation

    switch orientation {
    case .portrait:
      fallthrough
    case .landscapeLeft:
      fallthrough
    case .landscapeRight:
      self.setNeedsDisplay()
    default:
      return
    }
  }
  
  func clear() {
    faceOverlays = [FaceOverlay]()
    contentImageSize = CGSize.zero
    imageContentMode = .scaleAspectFit
    orientation = UIDevice.current.orientation
    edgeOffset = 0.0
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    for faceOverlay in faceOverlays {
      //drawDots(faceOverlay.dots)
        //for lineConnection in faceOverlay.lineConnections {
            drawLines(faceOverlay, lineColor:UIColor.red)
      //}
    }
  }

  // MARK: Private Functions
  private func rectAfterApplyingBoundsAdjustment(
    onOverlayBorderRect borderRect: CGRect) -> CGRect {

      var currentSize = self.bounds.size
      let minDimension = min(self.bounds.width, self.bounds.height)
      let maxDimension = max(self.bounds.width, self.bounds.height)

      switch orientation {
      case .portrait:
        currentSize = CGSizeMake(minDimension, maxDimension)
      case .landscapeLeft:
        fallthrough
      case .landscapeRight:
        currentSize = CGSizeMake(maxDimension, minDimension)
      default:
        break
      }

      let offsetsAndScaleFactor = OverlayView.offsetsAndScaleFactor(
        forImageOfSize: self.contentImageSize,
        tobeDrawnInViewOfSize: currentSize,
        withContentMode: imageContentMode)

      var newRect = borderRect
        .applying(
          CGAffineTransform(scaleX: offsetsAndScaleFactor.scaleFactor, y: offsetsAndScaleFactor.scaleFactor)
        )
        .applying(
          CGAffineTransform(translationX: offsetsAndScaleFactor.xOffset, y: offsetsAndScaleFactor.yOffset)
        )

      if newRect.origin.x < 0 &&
          newRect.origin.x + newRect.size.width > edgeOffset {
        newRect.size.width = newRect.maxX - edgeOffset
        newRect.origin.x = edgeOffset
      }

      if newRect.origin.y < 0 &&
          newRect.origin.y + newRect.size.height > edgeOffset {
        newRect.size.height += newRect.maxY - edgeOffset
        newRect.origin.y = edgeOffset
      }

      if newRect.maxY > currentSize.height {
        newRect.size.height = currentSize.height - newRect.origin.y  - edgeOffset
      }

      if newRect.maxX > currentSize.width {
        newRect.size.width = currentSize.width - newRect.origin.x - edgeOffset
      }

      return newRect
    }

  private func drawDots(_ dots: [CGPoint]) {
    for dot in dots {
      let dotRect = CGRect(
        x: CGFloat(dot.x) - DefaultConstants.pointRadius / 2,
        y: CGFloat(dot.y) - DefaultConstants.pointRadius / 2,
        width: DefaultConstants.pointRadius,
        height: DefaultConstants.pointRadius)
      let path = UIBezierPath(ovalIn: dotRect)
      DefaultConstants.pointFillColor.setFill()
      DefaultConstants.pointColor.setStroke()
      path.stroke()
      path.fill()
    }
  }

func drawLines(_ lines: FaceOverlay, lineColor: UIColor) {
    var path:CGPath? = nil
    var path1:CGPath? = nil
    let lineConections = lines.lineConnections[0]
       let lineConections1 = lines.lineConnections[1]
       let lines = lineConections.lines
       let lines1 = lineConections1.lines
    if let objType = lines[0].objType,
       let objType1 = lines1[0].objType {
        let rect = getObjectRectPath(lines, objType: objType)
        path = CGPath(rect: rect, transform: nil)
        let rect1 = getObjectRectPath(lines1, objType: objType1)
        path1 = CGPath(rect: rect1, transform: nil)
    }

    if let path = path {
        starLayer.path = path
    } else {
        starLayer.path = drawStarPathAtCenter(center: CGPoint(x: starLayer.frame.width / 2, y: starLayer.frame.height / 2)).cgPath
    }
    
    if let path1 = path1 {
        starLayer1.path = path1
    } else {
        starLayer1.path = drawStarPathAtCenter(center: CGPoint(x: starLayer1.frame.width / 2 - 100.0, y: starLayer1.frame.height / 2)).cgPath
    }
    let contentLayer = CALayer()
    contentLayer.addSublayer(starLayer)
    contentLayer.addSublayer(starLayer1)
    previewView.layer.addSublayer(contentLayer)
    previewView.layer.mask = contentLayer
    previewView.layer.masksToBounds = true
    previewView.layer.backgroundColor = UIColor.red.cgColor

    
//    let rect = getObjectRectPath(lines, objType: "leftEye")
//    let path1 = CGPath(rect: rect, transform: nil)
////    let maskLayer = CAShapeLayer()
////    maskLayer.path = path1
////    layer.addSublayer(maskLayer)
////    layer.mask = maskLayer
////    layer.masksToBounds = true
//    // Create a shape layer for the mask
//    backgroundColor = UIColor.red
//           let maskLayer = CAShapeLayer()
//           maskLayer.path = path1
//           
//           // Add the mask layer to your view's layer
//           layer.addSublayer(maskLayer)
//           
//           // Apply the mask to the view's layer
//           layer.mask = maskLayer
//        layer.masksToBounds = true
//           // Set the background color of the mask layer (optional)
//        maskLayer.fillColor = UIColor.blue.cgColor
//           
//           // Optionally, you can set the background color of your view
           
  }
    private func getObjectRectPath(_ lines: [Line], objType:String) -> CGRect {
        let objs = lines.filter { $0.objType == objType }
        let fromMinX = objs.map { $0.from.x}.min() ?? 0
        let toMinX = objs.map { $0.to.x}.min() ?? 0
        let fromMinY = objs.map { $0.from.y}.min() ?? 0
        let toMinY = objs.map { $0.to.y}.min() ?? 0

        let fromMaxX = objs.map { $0.from.x }.max() ?? 0
        let toMaxX = objs.map { $0.to.x }.max() ?? 0
        let fromMaxY = objs.map { $0.from.y }.max() ?? 0
        let toMaxY = objs.map { $0.to.y }.max() ?? 0

        // Calculate origin and end values for x and y
        let originX = min(toMinX, fromMinX)
        let endX = max(toMaxX, fromMaxX)
        let originY = min(toMinY, fromMinY)
        let endY = max(toMaxY, fromMaxY)

        // Print the results
        print("Origin X: \(originX), End X: \(endX)")
        print("Origin Y: \(originY), End Y: \(endY)")
        return CGRect(x: (originX - 25.0), y: (originY - 20), width: (endX - originX + 25.0) , height: (endY - originY + 20.0))
    }
    private func getObjectPath(_ lines: [Line], objType:String) -> CGPath {
        let objs = lines.filter { $0.objType == objType }
        let path = UIBezierPath()
        for line in objs {
          path.move(to: line.from)
          path.addLine(to: line.to)
        }
        return path.cgPath
    }
    private func drawLinesForBlackFace(_ lines: [Line], lineColor: UIColor) {
        guard let firstLine = lines.first else {
            // Return if the array is empty
            return
        }

        let path = UIBezierPath()
        
        // Move to the starting point of the first line
        path.move(to: firstLine.from)
        
        // Add lines to the path
        for line in lines {
            path.addLine(to: line.to)
        }

       // let scaleTransform = CGAffineTransform(scaleX: 1.6, y: 1.6)
       // path.apply(scaleTransform)
        // Close the path to create a closed shape
        path.close()
        
        // Set the fill color to black
        UIColor.black.setFill()
        
        // Fill the path with the specified color
        path.fill()
  //    let path = UIBezierPath()
  //    for line in lines {
  //      path.move(to: line.from)
  //      path.addLine(to: line.to)
  //    }
  //    path.lineWidth = DefaultConstants.lineWidth
  //    lineColor.setStroke()
  //    path.stroke()
    }
    
  // MARK: Helper Functions
  static func offsetsAndScaleFactor(
    forImageOfSize imageSize: CGSize,
    tobeDrawnInViewOfSize viewSize: CGSize,
    withContentMode contentMode: UIView.ContentMode)
  -> (xOffset: CGFloat, yOffset: CGFloat, scaleFactor: Double) {

    let widthScale = viewSize.width / imageSize.width;
    let heightScale = viewSize.height / imageSize.height;

    var scaleFactor = 0.0

    switch contentMode {
    case .scaleAspectFill:
      scaleFactor = max(widthScale, heightScale)
    case .scaleAspectFit:
      scaleFactor = min(widthScale, heightScale)
    default:
      scaleFactor = 1.0
    }

    let scaledSize = CGSize(
      width: imageSize.width * scaleFactor,
      height: imageSize.height * scaleFactor)
    let xOffset = (viewSize.width - scaledSize.width) / 2
    let yOffset = (viewSize.height - scaledSize.height) / 2

    return (xOffset, yOffset, scaleFactor)
  }

  // Helper to get object overlays from detections.
  class func faceOverlays(
    fromMultipleFaceLandmarks landmarks: [[NormalizedLandmark]],
    inferredOnImageOfSize originalImageSize: CGSize,
    ovelayViewSize: CGSize,
    imageContentMode: UIView.ContentMode,
    andOrientation orientation: UIImage.Orientation) -> [FaceOverlay] {

      var faceOverlays: [FaceOverlay] = []

      guard !landmarks.isEmpty else {
        return []
      }

      let offsetsAndScaleFactor = OverlayView.offsetsAndScaleFactor(
        forImageOfSize: originalImageSize,
        tobeDrawnInViewOfSize: ovelayViewSize,
        withContentMode: imageContentMode)

      for faceLandmarks in landmarks {
        var transformedFaceLandmarks: [CGPoint]!

        switch orientation {
        case .left:
          transformedFaceLandmarks = faceLandmarks.map({CGPoint(x: CGFloat($0.y), y: 1 - CGFloat($0.x))})
        case .right:
          transformedFaceLandmarks = faceLandmarks.map({CGPoint(x: 1 - CGFloat($0.y), y: CGFloat($0.x))})
        default:
          transformedFaceLandmarks = faceLandmarks.map({CGPoint(x: CGFloat($0.x), y: CGFloat($0.y))})
        }

        let dots: [CGPoint] = transformedFaceLandmarks.map({CGPoint(x: CGFloat($0.x) * originalImageSize.width * offsetsAndScaleFactor.scaleFactor + offsetsAndScaleFactor.xOffset, y: CGFloat($0.y) * originalImageSize.height * offsetsAndScaleFactor.scaleFactor + offsetsAndScaleFactor.yOffset)})

        var lineConnections: [LineConnection] = []
        lineConnections.append(LineConnection(
            // color: DefaultConstants.rightEyeConnectionsColor,
          lines: FaceLandmarker.rightEyeConnections()
          .map({ connection in
          let start = dots[Int(connection.start)]
          let end = dots[Int(connection.end)]
              return Line(from: start, to: end, objType: "rightEye")
        })))
        lineConnections.append(LineConnection(
          //color: DefaultConstants.leftEyeConnectionsColor,
          lines: FaceLandmarker.leftEyeConnections()
          .map({ connection in
          let start = dots[Int(connection.start)]
          let end = dots[Int(connection.end)]
              return Line(from: start, to: end, objType: "leftEye")
        })))

        faceOverlays.append(FaceOverlay(dots: dots, lineConnections: lineConnections))
      }
        let encoder = JSONEncoder()
        if let encodedData = try? encoder.encode(faceOverlays), let str = String(data: encodedData, encoding: .utf8) {
           // Do something with the encoded data
            print(str)
        }
      return faceOverlays
    }
    private func drawStarPathAtCenter(center:CGPoint) -> UIBezierPath {
       let starPath = UIBezierPath()

        let center = CGPoint(x: center.x, y: center.y)
       let radius = starLayer.frame.width / 2
       let innerRadius = radius * 0.5 // define inner radius

       var angle: CGFloat = -CGFloat.pi / 2
       let angleIncrement = CGFloat.pi * 2 / 5 // 5 points on the star
       let pointsOnStar = 5

       var firstPoint = true

       for _ in 0..<pointsOnStar {
           let point = pointFrom(angle, radius: radius, offset: center)
           let nextPoint = pointFrom(angle + angleIncrement, radius: radius, offset: center)
           let midPoint = pointFrom(angle + angleIncrement / 2.0, radius: innerRadius, offset: center)

           if firstPoint {
               firstPoint = false
               starPath.move(to: point)
           }

           starPath.addLine(to: midPoint)
           starPath.addLine(to: nextPoint)

           angle += angleIncrement
       }

       starPath.close()

       return starPath
    }
    private func pointFrom(_ angle: CGFloat, radius: CGFloat, offset: CGPoint) -> CGPoint {
       let x = offset.x + radius * cos(angle)
       let y = offset.y + radius * sin(angle)
       return CGPoint(x: x, y: y)
    }
}
