# Flutter Pulse Engine

**Flutter Pulse** is a performance-focused gesture processing engine for Flutter that improves gesture responsiveness under heavy computational workloads.

It uses a **two-tier execution pipeline** to keep latency-sensitive gesture handling on the UI isolate while moving computationally expensive recognition tasks to a background isolate.

---

## Overview

### The Problem

Flutter gesture recognition and UI rendering share the UI isolate. When gesture processing competes with expensive workloads such as:

* Heavy mathematical computation
* ML inference
* Multi-touch processing
* Handwriting/stroke recognition
* 3D animations

the UI isolate can become saturated, resulting in:

* Input latency
* UI stuttering
* Dropped frames
* Poor responsiveness, especially on low-end devices

### The Solution

Flutter Pulse separates gesture processing into two execution paths:

```text
                    Pointer Event
                         │
                         ▼
                ┌─────────────────┐
                │  Fast Classifier│
                │    O(1)         │
                └────────┬────────┘
                         │
               ┌─────────┴─────────┐
               │                   │
          Simple Gesture       Heavy Gesture
               │                   │
               ▼                   ▼
        ┌─────────────┐      ┌──────────────┐
        │  UI Isolate │      │ Worker       │
        │  Fast Path  │      │ Isolate      │
        └─────────────┘      └──────┬───────┘
                                    │
                                    ▼
                           Heavy Recognition
                                    │
                                    ▼
                              Result + seq
                                    │
                                    ▼
                              UI Isolate
```

---

## Architecture

### 1. Fast Path — UI Isolate

Simple gestures are handled immediately on the UI isolate.

A lightweight `FastClassifier` performs constant-time classification without waiting for the worker isolate.

Examples include:

* Simple taps
* Small pointer movements
* Linear scrolling

This minimizes communication overhead for common gestures.

---

### 2. Worker Path — Background Isolate

Computationally expensive operations are moved to a spawned worker isolate.

Examples include:

* Multi-touch recognition
* Handwriting stroke detection
* Heavy mathematical processing
* ML-style computation

The worker communicates with the UI isolate using Dart's isolate messaging system:

```text
UI Isolate
    │
    │ SendPort
    ▼
Worker Isolate
    │
    │ SendPort
    ▼
UI Isolate
```

This prevents expensive computation from blocking frame rendering.

---

### 3. Event Safety Layer

Because worker results can arrive after newer pointer events have already been processed, Flutter Pulse uses an event-safety mechanism.

Each event is identified using:

```text
{ seq, gestureId }
```

The system uses:

* **Sequence numbers** — identify the freshness of events
* **Gesture IDs** — associate events with a specific gesture
* **Coalescing/throttling** — reduce unnecessary event processing
* **Backpressure control** — prevent the worker queue from growing uncontrollably
* **Cancellation flags** — discard work that is no longer relevant
* **Stale-result filtering** — prevent outdated worker responses from updating the UI

The goal is to ensure that the UI always consumes the most relevant gesture state.

---

# Performance Telemetry

Flutter Pulse includes a live telemetry overlay for measuring the performance of both execution paths.

## UI p50 Latency

UI latency measures the time between receiving a pointer movement and the subsequent frame callback.

### Measurement

A `Stopwatch` is started when the pointer event is dispatched:

```dart
final stopwatch = Stopwatch()..start();
```

The measurement is completed using:

```dart
WidgetsBinding.instance.addPostFrameCallback((_) {
  stopwatch.stop();
});
```

The resulting latency samples are stored in a rolling buffer containing the latest **100 samples**.

The samples are sorted and the median (`p50`) is calculated.

For `N` samples:

```text
p50 index = round((N - 1) × 0.5)
```

---

## Worker p50 Latency

Worker latency measures the processing time inside the background isolate.

The worker starts a `Stopwatch` when it receives an event containing:

```text
gestureId
seq
dx
dy
```

The worker then performs computationally expensive processing.

For benchmarking, the current implementation simulates heavy ML-style computation using approximately **3,000,000 trigonometric operations** involving `sin()` and `cos()`.

Once processing finishes, the worker sends the result back to the UI isolate:

```text
Worker
  │
  ├── Compute
  │
  └── elapsedMilliseconds
           │
           ▼
       UI Isolate
```

The response is tagged with its sequence number so stale results can be discarded.

---

# Gesture Path Classification

Flutter Pulse tracks how pointer events are distributed between the fast and heavy execution paths.

### Fast Path

Small pointer movements are classified as lightweight when:

```text
|dx| <= 8
AND
|dy| <= 8
```

These events are processed immediately on the UI isolate.

### Heavy Path

The current diagonal classifier sends events to the worker when:

```text
dx > 8
AND
dy > 8
```

This allows computationally expensive gesture recognition to execute outside the UI isolate.

---

# Project Structure

The core architecture is organized around the following components:

```text
Flutter Pulse
│
├── FastPathWidget
│
├── FastPathController
│
├── FastPathClassifier
│
├── FastPathWorkerRegistry
│
└── heavyWorker
```

### Core Components

| Component                | Responsibility                                     |
| ------------------------ | -------------------------------------------------- |
| `FastPathWidget`         | Integrates the gesture engine with the Flutter UI  |
| `FastPathController`     | Coordinates gesture processing                     |
| `FastPathClassifier`     | Performs lightweight gesture classification        |
| `FastPathWorkerRegistry` | Manages worker-isolate lifecycle and communication |
| `heavyWorker`            | Executes computationally expensive recognition     |

---

# Setup

## Prerequisites

### Flutter

Flutter SDK **3.0.0 or later**.

### Windows Desktop

For native Windows isolate execution, install:

* Visual Studio 2022
* Desktop development with C++
* MSVC build tools
* C++ CMake tools
* Windows 10/11 SDK

---

# Installation

Add Flutter to your system `PATH`.

Example on Windows:

```cmd
set PATH=%PATH%;D:\flutter_windows_3.47.4-stable\flutter\bin
```

Verify the installation:

```cmd
flutter doctor
```

---

# Running the Project

Navigate to the project directory:

```cmd
cd D:\flutter_pulse_phase3
```

Install dependencies:

```cmd
flutter pub get
```

## Run on Chrome

The web implementation uses a stream-based isolate fallback:

```cmd
flutter run -d chrome
```

## Run as Windows Desktop

The native Windows implementation uses actual background OS isolates:

```cmd
flutter run -d windows
```

---

# Web vs Native Execution

| Environment      | Execution Model               |
| ---------------- | ----------------------------- |
| Chrome           | Stream-based isolate fallback |
| Windows          | Native background OS isolate  |
| UI processing    | UI isolate                    |
| Heavy processing | Worker isolate                |

The native Windows target is particularly useful for evaluating the benefits of parallel computation without relying on the web fallback.

---

# Performance Model

The engine follows a simple principle:

```text
Keep latency-sensitive work small.
Move expensive computation away from the UI isolate.
```

Instead of processing every gesture through the expensive recognition pipeline:

```text
Pointer Event
     │
     ▼
Heavy Processing
     │
     ▼
UI
```

Flutter Pulse attempts to use:

```text
                 Pointer Event
                      │
              ┌───────┴───────┐
              ▼               ▼
        Fast Classifier   Heavy Classifier
              │               │
              ▼               ▼
         UI Isolate      Worker Isolate
              │               │
              └───────┬───────┘
                      ▼
                     UI
```

This reduces the amount of expensive computation competing directly with frame rendering.

---

# Key Features

* Lightweight **O(1) fast-path gesture classification**
* Background processing using **Dart isolates**
* Sequence-based event ordering
* Gesture-aware event tracking
* Stale result rejection
* Backpressure control
* Event coalescing/throttling
* Cancellation support
* Live UI latency telemetry
* Worker latency telemetry
* Fast-path vs heavy-path statistics
* Windows native execution
* Web execution fallback

---

# Future Work

### Standalone Flutter Package

The next step is to extract the core engine into an independent Pub package:

```text
flutter_pulse
```

The package would expose reusable components such as:

```text
FastPathWidget
FastPathController
FastPathClassifier
FastPathWorkerRegistry
```

The goal is to allow developers to integrate isolate-driven gesture processing into existing Flutter applications with minimal boilerplate.

Potential future improvements include:

* More sophisticated gesture classifiers
* Adaptive worker scheduling
* Improved cancellation mechanisms
* Dynamic backpressure thresholds
* More detailed frame-performance telemetry
* Real ML-based gesture recognition
* Mobile-device benchmarking
* Automatic workload classification
* Multi-worker isolate pools

---

# Tech Stack

* **Flutter**
* **Dart**
* **Dart Isolates**
* **Flutter Widgets**
* **SendPort / ReceivePort**
* **Windows Desktop**
* **Chrome / Flutter Web**

---

# License

This project is currently intended as a research/prototype implementation for exploring responsive gesture processing and isolate-based workload separation in Flutter.
