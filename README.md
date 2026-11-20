# box2boxcam iOS app

The iPhone app of [box2boxcam](https://github.com/Thibault-GILLARD/box2boxcam-football-vision): it turns an iPhone on a phone gimbal into the cameraman of your amateur football match. Everything runs live on the phone, about 30 times a second.


https://github.com/user-attachments/assets/063bcb82-53c0-44c3-a6fe-a5bb95799286


![A real night match filmed with nobody behind the camera](https://github.com/Thibault-GILLARD/box2boxcam-football-vision/raw/main/docs/assets/demo_real_match.gif)

**Status: in development.** It has filmed real matches, but it is a working prototype, not a finished app. The interface is in French for now. Tested on an iPhone 17 with a DJI Osmo Mobile 8P.

## How it works

1. **Find the ball and the players.** Core ML runs the open [box2boxcam ball model](https://huggingface.co/Totorotibo84/box2boxcam-football-ball-detection) (YOLO26s fine-tuned for small balls, 960 px), a stock YOLO26s person detector and YOLO26s-pose on each analysed frame.
2. **Pick where to film.** A hybrid rule follows the ball while its track is reliable, and falls back on the players (where they stand and where they face) when the ball is lost. People off the pitch are filtered out with a two-tap pitch calibration (tap the foot of each goal).
3. **Move the gimbal.** The app turns off the gimbal's built-in tracking and drives the motors itself through Apple's [DockKit](https://developer.apple.com/documentation/dockkit), over Bluetooth. It sends pan and tilt **velocities** (`setAngularVelocity`, in rad/s, capped at 0.30 rad/s), updated with each analysis: the further the target is from the centre of the image, the faster the camera turns. A zero command is re-sent every second so the gimbal does not take back control.



## What you need

- An iPhone running iOS 18.5 or later, and Xcode.
- A gimbal that lets an app move its motors, which on iPhone means a DockKit gimbal (DJI Osmo Mobile 8 / 8P, Insta360 Flow 2 Pro…). Only the Osmo Mobile 8P has been tested.
- Python 3, to fetch the models.

## Build

```sh
git clone https://github.com/Thibault-GILLARD/box2boxcam-ios.git
cd box2boxcam-ios
scripts/fetch-models.sh   # downloads the ball model from Hugging Face, exports the person and pose models
open PitchLensDockKit.xcodeproj
```

In Xcode, pick your own team under *Signing & Capabilities* (and a unique bundle identifier), then run on your iPhone. Pair the gimbal with the iPhone (NFC tap on the Osmo), open the app, and start a match.

## Code map

| Where | What |
| --- | --- |
| `DockKitCore/` | Platform-independent logic, testable on a Mac: camera policy (`HybridCameraPolicy`), motor control (`MotorController`), pitch calibration (`PitchCalibration`), ball tracking and search window. |
| `PitchLensDockKit/DockKitTransport.swift` | The DockKit bridge: manual control and velocity commands. |
| `PitchLensDockKit/BallDetector.swift`, `HybridVisionProcessor.swift` | Core ML inference for the ball, people and poses. |
| `PitchLensDockKit/DockKitModel.swift` | Wires camera, detection, policy and motors together. |
| `scripts/check-dockkit.sh` | Project checks, the `DockKitCore` checks, and an unsigned iOS build. |

Run the core checks without Xcode:

```sh
swift run --package-path DockKitCore MotorControllerChecks
```

## Contributing

Issues and pull requests are welcome, especially tests with other DockKit gimbals and iPhones. The ball model, dataset and training code live in [box2boxcam-football-vision](https://github.com/Thibault-GILLARD/box2boxcam-football-vision).

## License

[AGPL-3.0](LICENSE). The person and pose models come from [Ultralytics](https://github.com/ultralytics/ultralytics) (AGPL-3.0). Inter Tight is under the SIL Open Font License (`PitchLensDockKit/Fonts/OFL.txt`).
