# Flutter Pulse Engine

A performance-focused gesture processing engine for Flutter that reduces UI-isolate contention by routing lightweight gesture events through a fast path and computationally expensive events to a background isolate.

## Overview

Flutter applications rely heavily on the UI isolate for BOTH rendering and user interaction. Expensive gesture processing can therefore compete with frame rendering and introduce:
- Input latency
- Frame drops
- UI stuttering
- Reduced responsiveness under computational workloads

**Flutter Pulse** addresses this using a dual-path execution architecture:

```text
                         Pointer Event
                              │
                              ▼
                    ┌──────────────────┐
                    │ Fast Classifier  │
                    │      O(1)        │
                    └────────┬─────────┘
                             │
                   ┌─────────┴─────────┐
                   │                   │
              Fast Path           Heavy Path
                   │                   │
                   ▼                   ▼
             UI Isolate         Worker Isolate
                   │                   │
                   │            Heavy Processing
                   │                   │
                   └─────────┬─────────┘
                             ▼
                       Gesture Result
```

## Fast Path

Lightweight gesture events are processed directly on the UI isolate using an **O(1) classifier**, avoiding unnecessary isolate communication overhead.

## Heavy Path

Computationally expensive events are dispatched to a **background isolate**, keeping heavy processing away from the UI thread. Event sequencing and stale-result filtering ensure outdated results are not applied.

## Performance Telemetry

The engine tracks:

- UI latency
- Worker latency
- p50 (median) latency
- Fast-path vs. heavy-path event distribution

## Running
```bash
flutter pub get
```
```bash
in chrome
flutter run -d chrome
```
```bash
in windows
flutter run -d windows
```
### Prerequisites

- Flutter SDK
- Dart SDK

```bash
flutter pub get
