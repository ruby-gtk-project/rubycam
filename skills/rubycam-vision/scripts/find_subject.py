#!/usr/bin/env python3
"""Locate faces in a webcam frame and print gimbal corrections to center one.

Usage: find_subject.py PHOTO [--fov DEGREES]

Runs OpenCV's YuNet face detector (downloads the ~230KB ONNX model beside
this script on first use) and, for the largest face, prints the pan/tilt
delta that centers it — already in rubycam's 1/3600-degree units and already
following the OBSBOT Tiny 2 conventions (horizontally mirrored frame: a
subject on the image's left needs pan_absolute increased).

Offsets are relative fractions of the frame, so a downsized/prepped copy of
the photo gives the same answer as the original — feed it the prepped file.
"""
import argparse
import pathlib
import sys
import urllib.request

import cv2

MODEL_URL = ("https://github.com/opencv/opencv_zoo/raw/main/models/"
             "face_detection_yunet/face_detection_yunet_2023mar.onnx")
MODEL = pathlib.Path(__file__).with_name("face_detection_yunet_2023mar.onnx")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("image")
    ap.add_argument("--fov", type=float, default=80.0,
                    help="horizontal field of view in degrees at the current "
                         "zoom (Tiny 2 at zoom 0: ~80)")
    args = ap.parse_args()

    if not MODEL.exists():
        urllib.request.urlretrieve(MODEL_URL, MODEL)

    img = cv2.imread(args.image)
    if img is None:
        sys.exit(f"cannot read image: {args.image}")
    h, w = img.shape[:2]

    detector = cv2.FaceDetectorYN.create(str(MODEL), "", (w, h),
                                         score_threshold=0.6)
    _, faces = detector.detect(img)
    if faces is None or len(faces) == 0:
        print("no faces found (try the auto-leveled prepped copy, or a "
              "lower zoom / different pan)")
        return

    # Highest confidence first — a big low-score box is usually a hand or
    # shadow, not the subject.
    faces = sorted(faces, key=lambda f: f[-1], reverse=True)
    for i, f in enumerate(faces):
        x, y, fw, fh, score = f[0], f[1], f[2], f[3], f[-1]
        print(f"face {i + 1}: bbox=({x:.0f},{y:.0f},{fw:.0f},{fh:.0f}) "
              f"score={score:.2f}")

    x, y, fw, fh = faces[0][:4]
    # Fraction of half-frame the face center sits off axis (+right, +down).
    off_x = (x + fw / 2 - w / 2) / (w / 2)
    off_y = (y + fh / 2 - h / 2) / (h / 2)
    # Mirrored frame: image-left => pan +. Vertical is not mirrored, but
    # image y grows downward while tilt + is up, so both axes negate.
    vfov = args.fov * h / w
    pan_deg = -off_x * args.fov / 2
    tilt_deg = -off_y * vfov / 2

    print(f"best face offset: x={off_x:+.0%} y={off_y:+.0%} of half-frame")
    # pan/tilt step is 3600 (whole degrees), so round the delta to degrees
    print(f"pan  correction: {pan_deg:+6.1f} deg => pan_absolute  += {round(pan_deg) * 3600:+d}")
    print(f"tilt correction: {tilt_deg:+6.1f} deg => tilt_absolute += {round(tilt_deg) * 3600:+d}")
    print("apply with: rubycam get pan_absolute; rubycam set -- pan_absolute "
          "<current + delta>   (same for tilt)")


if __name__ == "__main__":
    main()
