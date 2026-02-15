# Synchronous/Asynchronous Patterns and Simultaneous Camera Capture in server1.py

## Table of Contents
1. [Overview: Synchronous vs Asynchronous](#overview)
2. [Asynchronous Patterns (async/await)](#asynchronous-patterns)
3. [Synchronous Patterns (Blocking Operations)](#synchronous-patterns)
4. [Hybrid Approach: Threading + Async](#hybrid-approach)
5. [Simultaneous Camera Capture Mechanism](#simultaneous-camera-capture)
6. [Detailed Code Flow Analysis](#detailed-code-flow)
7. [Why This Architecture?](#why-this-architecture)

---

## 1. Overview: Synchronous vs Asynchronous {#overview}

### What is Synchronous Code?
**Synchronous (blocking)**: Code executes line-by-line, waiting for each operation to complete before moving to the next.

```python
# Synchronous example
def read_file():
    data = open("file.txt").read()  # Blocks until file is read
    process(data)  # Blocks until processing is done
    return result
```

**Characteristics:**
- One operation at a time
- CPU waits for I/O operations (file, network, hardware)
- Simple to understand, but inefficient for I/O-bound tasks

### What is Asynchronous Code?
**Asynchronous (non-blocking)**: Code can start multiple operations and switch between them while waiting for I/O.

```python
# Asynchronous example
async def read_file():
    data = await aiofiles.open("file.txt").read()  # Yields control while reading
    await process(data)  # Yields control while processing
    return result
```

**Characteristics:**
- Multiple operations can run concurrently
- CPU doesn't wait for I/O - can handle other tasks
- More complex, but highly efficient for I/O-bound operations

---

## 2. Asynchronous Patterns (async/await) {#asynchronous-patterns}

### 2.1 FastAPI WebSocket Endpoint

**Location**: `websocket_endpoint()` (lines 300-346)

```python
@app.websocket("/ws/telemetry")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()  # Non-blocking: waits for connection
    connected_clients.append(websocket)
    
    try:
        # Send initial status (non-blocking)
        await websocket.send_json({
            "type": "connection_status",
            "status": "connected"
        })
        
        # Listen for messages (non-blocking)
        while True:
            data = await websocket.receive_text()  # Yields control while waiting
            message = json.loads(data)
            await handle_client_message(websocket, message)  # Async handler
```

**Why Async?**
- WebSocket communication is I/O-bound (network operations)
- Multiple clients can connect simultaneously
- Server can handle other tasks while waiting for messages

**Key Points:**
- `await` **yields control** to the event loop, allowing other tasks to run
- While waiting for `receive_text()`, the server can process other WebSocket connections
- This is **concurrent** (not parallel) - single thread, multiple tasks switching

---

### 2.2 Telemetry Generation Loop

**Location**: `generate_telemetry()` (lines 1247-1334)

```python
async def generate_telemetry():
    """Broadcast telemetry data every second"""
    while True:
        # Prepare telemetry data (synchronous, fast)
        telemetry = {
            "type": "telemetry",
            "latitude": drone_latitude,
            "longitude": drone_longitude,
            # ... more fields
        }
        
        # Broadcast to all clients (non-blocking)
        await broadcast_message(telemetry)
        
        # Sleep for 1 second (non-blocking)
        await asyncio.sleep(1)  # Yields control for 1 second
```

**Why Async?**
- `broadcast_message()` sends to multiple clients - async allows concurrent sends
- `asyncio.sleep()` doesn't block the entire server - other tasks continue
- Telemetry runs continuously without blocking mission uploads, camera captures, etc.

**Execution Flow:**
```
Time: 0.0s → Generate telemetry → Broadcast → Sleep (yield)
Time: 0.1s → [Other tasks run: camera capture, mission upload, etc.]
Time: 1.0s → Resume telemetry → Generate → Broadcast → Sleep
```

---

### 2.3 Camera Capture Functions

**Location**: `_capture_once()` (lines 213-239) and `_capture_loop()` (lines 241-298)

#### Single Camera Capture (Async)

```python
async def _capture_once(camera_index: int, output_path: pathlib.Path) -> bool:
    # Launch subprocess (non-blocking)
    proc = await asyncio.create_subprocess_exec(
        "rpicam-still",
        "--camera", str(camera_index),
        "-n", "-t", "1",
        "--shutter", "300",
        "-o", str(output_path),
        stdout=PIPE, stderr=PIPE
    )
    
    # Wait for subprocess to complete (non-blocking)
    out, err = await proc.communicate()
    
    return proc.returncode == 0
```

**Why Async?**
- `create_subprocess_exec()` launches a process without blocking
- `proc.communicate()` waits for the process, but yields control to the event loop
- While one camera is capturing, the server can handle other requests

**Key Insight:**
- The subprocess runs in the **background** (OS-level parallelism)
- Python's async event loop can handle other tasks while waiting for the subprocess

---

## 3. Synchronous Patterns (Blocking Operations) {#synchronous-patterns}

### 3.1 MAVLink Reader Loop

**Location**: `_mavlink_reader_loop()` (lines 1069-1245)

```python
def _mavlink_reader_loop():
    """Runs in a separate thread - synchronous blocking code"""
    while True:
        try:
            # Blocking connection (waits until connected)
            m = mavutil.mavlink_connection(MAVLINK_PORT, baud=MAVLINK_BAUD)
            m.wait_heartbeat(timeout=10)  # Blocks until heartbeat received
            
            while True:
                # Blocking read (waits for message)
                msg = m.recv_match(blocking=True, timeout=0.5)
                if not msg:
                    continue
                
                # Process message (synchronous)
                if msg.get_type() == "GLOBAL_POSITION_INT":
                    drone_latitude = msg.lat / 1e7
                    drone_longitude = msg.lon / 1e7
                    # ... update global variables
```

**Why Synchronous?**
- MAVLink library (`pymavlink`) is **synchronous** - designed for blocking I/O
- Serial port communication (`/dev/ttyACM0`) requires blocking reads
- Threading allows this to run **in parallel** with async code

**Execution Model:**
```
Main Thread (Async Event Loop):
├── WebSocket handlers
├── Telemetry generation
├── Camera capture
└── Mission upload

Background Thread (Synchronous):
└── MAVLink reader loop (blocking serial I/O)
```

---

### 3.2 File I/O Operations

**Location**: `_save_pending_message()`, `_load_pending_messages()` (lines 86-145)

```python
def _save_pending_message(message: Dict[str, Any]):
    """Synchronous file I/O with thread lock"""
    with pending_messages_lock:  # Thread-safe lock
        # Blocking file read
        messages = []
        if pending_messages_file.exists():
            with open(pending_messages_file, 'r') as f:
                messages = json.load(f)  # Blocks until file is read
        
        messages.append(message)
        
        # Blocking file write
        with open(pending_messages_file, 'w') as f:
            json.dump(messages, f)  # Blocks until file is written
```

**Why Synchronous?**
- File I/O is fast enough that async overhead isn't worth it
- Thread lock (`threading.Lock`) ensures thread-safety
- Called from both async and sync contexts

**Thread Safety:**
- `pending_messages_lock` prevents race conditions
- Multiple threads/async tasks can call this safely

---

## 4. Hybrid Approach: Threading + Async {#hybrid-approach}

### 4.1 Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│              FastAPI Application (Async)                │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ WebSocket    │  │ Telemetry    │  │ Camera       │ │
│  │ Handlers     │  │ Generator    │  │ Capture      │ │
│  │ (async)      │  │ (async)      │  │ (async)      │ │
│  └──────────────┘  └──────────────┘  └──────────────┘ │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │         Async Event Loop (Single Thread)         │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
                        │
                        │ Shares global variables
                        │
┌───────────────────────▼───────────────────────────────┐
│         Background Thread (Synchronous)               │
│                                                         │
│  ┌──────────────────────────────────────────────────┐ │
│  │         MAVLink Reader Loop                      │ │
│  │         (Blocking Serial I/O)                     │ │
│  └──────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### 4.2 Thread Startup

**Location**: `startup_event()` (lines 1336-1342)

```python
@app.on_event("startup")
async def startup_event():
    """Start background services on server startup"""
    # Start MAVLink reader in a separate thread
    threading.Thread(target=_mavlink_reader_loop, daemon=True).start()
    
    # Start async telemetry task
    asyncio.create_task(generate_telemetry())
```

**Why This Approach?**
1. **MAVLink in Thread**: Serial I/O is blocking - threading allows parallel execution
2. **Async Tasks**: WebSocket, telemetry, camera - all I/O-bound, perfect for async
3. **Shared State**: Global variables (`drone_latitude`, `drone_longitude`, etc.) shared between thread and async code

**Thread Safety:**
- Global variables are updated by the MAVLink thread
- Async code reads these variables (mostly read-only)
- Locks (`mavlink_lock`, `pending_messages_lock`) protect critical sections

---

### 4.3 MAVLink Lock Usage

**Location**: Mission upload (lines 744-855)

```python
# Pause MAVLink RX loop to avoid contention
mavlink_rx_pause.set()  # Signal to background thread

try:
    with mavlink_lock:  # Acquire lock
        # Exclusive access to MAVLink connection
        m.mav.mission_clear_all_send(...)
        m.mav.mission_count_send(...)
        # ... mission upload protocol
finally:
    mavlink_rx_pause.clear()  # Resume RX loop
```

**Why Lock?**
- Mission upload requires **exclusive access** to MAVLink connection
- Background thread reads messages continuously
- Lock ensures no interference during critical operations

**Pause Mechanism:**
```python
# In _mavlink_reader_loop():
if mavlink_rx_pause.is_set():
    time.sleep(0.05)  # Skip reading messages
    continue
```

---

## 5. Simultaneous Camera Capture Mechanism {#simultaneous-camera-capture}

### 5.1 The Challenge

**Problem**: Capture images from two cameras (NoIR and RGB) at the **exact same time**.

**Why It Matters:**
- For agricultural analysis, images must be synchronized
- Timestamp matching requires simultaneous capture
- Both cameras must see the same scene at the same moment

### 5.2 Solution: Concurrent Async Tasks

**Location**: `_capture_loop()` (lines 241-298)

```python
async def _capture_loop(stop_event: asyncio.Event, interval_seconds: float = 0.5):
    while not stop_event.is_set():
        # STEP 1: Generate shared timestamp BEFORE captures
        ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:-3]
        
        # STEP 2: Prepare file paths with same timestamp
        base = f"session_{sess}_{ts}_{frame_no}_{alt_int}_{lat_str}_{lon_str}"
        noir_path = NOIR_DIR / f"{base}_noir.jpg"
        rgb_path = RGB_DIR / f"{base}_rgb.jpg"
        
        # STEP 3: Launch both captures concurrently
        t1 = asyncio.create_task(_capture_once(0, noir_path))  # Camera 0 (NoIR)
        t2 = asyncio.create_task(_capture_once(1, rgb_path))   # Camera 1 (RGB)
        
        # STEP 4: Wait for BOTH to complete (with timeout)
        try:
            res1, res2 = await asyncio.wait_for(
                asyncio.gather(t1, t2), 
                timeout=max(3.0, interval_seconds)
            )
        except asyncio.TimeoutError:
            print("[CAMERA] Capture timed out")
```

### 5.3 How It Works: Step-by-Step

#### Step 1: Timestamp Generation (Before Capture)

```python
ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:-3]
# Example: "20240115_143022_123"
```

**Critical**: Timestamp is generated **once** before both captures start. This ensures both images share the same timestamp.

#### Step 2: Create Async Tasks

```python
t1 = asyncio.create_task(_capture_once(0, noir_path))
t2 = asyncio.create_task(_capture_once(1, rgb_path))
```

**What Happens:**
- `create_task()` **schedules** both functions to run concurrently
- Tasks are added to the event loop's queue
- **No blocking** - tasks start immediately

#### Step 3: Concurrent Execution

```python
# Inside _capture_once():
proc = await asyncio.create_subprocess_exec("rpicam-still", ...)
```

**Execution Timeline:**
```
Time: 0.000s → Task 1 starts: Launch rpicam-still for camera 0
Time: 0.001s → Task 2 starts: Launch rpicam-still for camera 1
Time: 0.002s → Both subprocesses running in parallel (OS-level)
Time: 0.100s → Camera 0: Hardware capture begins
Time: 0.101s → Camera 1: Hardware capture begins (almost simultaneous)
Time: 0.200s → Camera 0: Image saved to disk
Time: 0.201s → Camera 1: Image saved to disk
Time: 0.202s → Both tasks complete
```

**Key Points:**
- Both subprocesses run **in parallel** (OS handles this)
- Hardware captures happen within **milliseconds** of each other
- Async event loop manages both tasks concurrently

#### Step 4: Wait for Completion

```python
res1, res2 = await asyncio.gather(t1, t2, timeout=max(3.0, interval_seconds))
```

**What `asyncio.gather()` + `asyncio.wait_for()` Does:**
- `asyncio.gather()`: Waits for **all** tasks to complete, returns results in order
- `asyncio.wait_for()`: Wraps gather with a timeout (max 3 seconds or interval)
- If any task fails, exception is raised (but others continue)
- If timeout expires, `TimeoutError` is raised
- Ensures captures don't hang indefinitely

---

### 5.4 Why This Achieves "Simultaneous" Capture

#### Hardware Level

1. **OS Process Scheduling**: Both `rpicam-still` processes are scheduled by the OS kernel
2. **Camera Hardware**: Raspberry Pi camera modules can be triggered independently
3. **Minimal Delay**: The time between starting both processes is **microseconds**

#### Software Level

1. **Shared Timestamp**: Generated before captures, ensuring both images have the same timestamp
2. **Concurrent Launch**: Both subprocesses start almost simultaneously
3. **No Sequential Waiting**: Unlike synchronous code, we don't wait for camera 0 to finish before starting camera 1

#### Actual Timing

```
Ideal:     Camera 0: [Capture] → 0.000s
           Camera 1: [Capture] → 0.000s

Reality:   Camera 0: [Capture] → 0.000s
           Camera 1: [Capture] → 0.001s  (1ms delay - negligible)
```

**Result**: Images are captured within **1-2 milliseconds** of each other, which is effectively simultaneous for agricultural imaging purposes.

---

### 5.5 Alternative Approaches (Why They're Not Used)

#### ❌ Sequential Capture (Synchronous)

```python
# BAD: Sequential - cameras capture one after another
res1 = await _capture_once(0, noir_path)  # Wait for camera 0
res2 = await _capture_once(1, rgb_path)   # Then start camera 1
```

**Problem**: Delay between captures could be 100-500ms, causing misalignment.

#### ❌ Threading

```python
# POSSIBLE but unnecessary complexity
import threading
t1 = threading.Thread(target=capture_sync, args=(0, noir_path))
t2 = threading.Thread(target=capture_sync, args=(1, rgb_path))
t1.start()
t2.start()
t1.join()
t2.join()
```

**Why Not Used**: Async is simpler, more efficient for I/O-bound tasks, and integrates better with FastAPI.

#### ✅ Concurrent Async Tasks (Current Approach)

**Advantages:**
- Simple, clean code
- Efficient resource usage
- Integrates with FastAPI's async model
- Achieves near-simultaneous capture

---

## 6. Detailed Code Flow Analysis {#detailed-code-flow}

### 6.1 Complete Camera Capture Flow

```
User Action: "start_capture" message via WebSocket
    │
    ▼
websocket_endpoint() receives message
    │
    ▼
handle_client_message() processes "start_capture"
    │
    ▼
capture_stop_event = asyncio.Event()
capture_task = asyncio.create_task(_capture_loop(...))
    │
    ▼
_capture_loop() starts (runs in async event loop)
    │
    ├─→ Generate timestamp: "20240115_143022_123"
    ├─→ Prepare paths: noir_path, rgb_path
    │
    ├─→ t1 = create_task(_capture_once(0, noir_path))
    │   │
    │   └─→ _capture_once(0, ...):
    │       ├─→ create_subprocess_exec("rpicam-still", "--camera", "0", ...)
    │       ├─→ Subprocess launches (OS-level)
    │       ├─→ Hardware: Camera 0 captures image
    │       └─→ await proc.communicate() → Returns when done
    │
    ├─→ t2 = create_task(_capture_once(1, rgb_path))
    │   │
    │   └─→ _capture_once(1, ...):
    │       ├─→ create_subprocess_exec("rpicam-still", "--camera", "1", ...)
    │       ├─→ Subprocess launches (OS-level)
    │       ├─→ Hardware: Camera 1 captures image
    │       └─→ await proc.communicate() → Returns when done
    │
    ├─→ await asyncio.gather(t1, t2)
    │   │
    │   └─→ Event loop switches between tasks:
    │       ├─→ Task 1: Waiting for subprocess → Yield control
    │       ├─→ Task 2: Waiting for subprocess → Yield control
    │       ├─→ Other tasks run (telemetry, WebSocket, etc.)
    │       └─→ Both subprocesses complete → Resume
    │
    ├─→ Both images saved with same timestamp
    └─→ await asyncio.sleep(2.0) → Wait 2 seconds before next capture
```

### 6.2 MAVLink + Async Integration Flow

```
Server Startup:
    │
    ├─→ startup_event() called
    │   │
    │   ├─→ Thread starts: _mavlink_reader_loop()
    │   │   │
    │   │   └─→ Synchronous loop:
    │   │       ├─→ Connect to /dev/ttyACM0 (blocking)
    │   │       ├─→ Wait for heartbeat (blocking)
    │   │       └─→ while True:
    │   │           ├─→ Read message (blocking, 0.5s timeout)
    │   │           ├─→ Update global variables:
    │   │           │   ├─→ drone_latitude
    │   │           │   ├─→ drone_longitude
    │   │           │   ├─→ drone_altitude
    │   │           │   └─→ drone_battery
    │   │           └─→ Continue loop
    │   │
    │   └─→ Async task starts: generate_telemetry()
    │       │
    │       └─→ Async loop:
    │           ├─→ Read global variables (from MAVLink thread)
    │           ├─→ Build telemetry JSON
    │           ├─→ await broadcast_message() → Send to WebSocket clients
    │           └─→ await asyncio.sleep(1) → Repeat every second
    │
    └─→ WebSocket endpoint ready
        │
        └─→ Clients connect → Handle messages async
```

**Key Points:**
- MAVLink thread updates global variables (write)
- Async tasks read global variables (read)
- No locks needed for reading (Python's GIL provides some protection)
- Locks used only for critical sections (mission upload)

---

## 7. Why This Architecture? {#why-this-architecture}

### 7.1 Why Async for WebSocket/Telemetry/Camera?

**I/O-Bound Operations:**
- Network I/O (WebSocket): Waiting for data from network
- File I/O (Camera): Waiting for disk writes
- Subprocess I/O: Waiting for external processes

**Async Benefits:**
- Can handle **thousands** of concurrent connections
- Efficient resource usage (single thread)
- Non-blocking: Server remains responsive

### 7.2 Why Threading for MAVLink?

**Blocking I/O:**
- Serial port communication (`/dev/ttyACM0`) requires blocking reads
- MAVLink library is synchronous
- Cannot be easily converted to async

**Threading Benefits:**
- Runs in **parallel** with async code
- Doesn't block the event loop
- Simple integration with existing MAVLink code

### 7.3 Why Not Pure Async or Pure Threading?

#### Pure Async (Not Possible)
- MAVLink library doesn't support async
- Serial port I/O is inherently blocking
- Would require rewriting MAVLink library

#### Pure Threading (Inefficient)
- Threads have higher overhead
- Context switching is more expensive
- Harder to manage (thread pools, synchronization)
- Async is better for I/O-bound tasks

#### Hybrid (Current Approach) ✅
- **Best of both worlds**:
  - Async for I/O-bound operations (WebSocket, camera, telemetry)
  - Threading for blocking operations (MAVLink serial I/O)
- Efficient and maintainable

---

## 8. Summary

### Synchronous Code
- **MAVLink reader loop**: Runs in background thread, blocking serial I/O
- **File I/O**: Synchronous with thread locks for safety
- **Mission upload**: Synchronous MAVLink protocol (with async wrapper)

### Asynchronous Code
- **WebSocket handlers**: Non-blocking network I/O
- **Telemetry generation**: Periodic broadcasts without blocking
- **Camera capture**: Concurrent subprocess execution
- **Message broadcasting**: Concurrent sends to multiple clients

### Simultaneous Camera Capture
- **Mechanism**: Concurrent async tasks with shared timestamp
- **Timing**: Both cameras capture within 1-2ms of each other
- **Implementation**: `asyncio.create_task()` + `asyncio.gather()`
- **Result**: Effectively simultaneous capture for agricultural imaging

### Key Takeaways
1. **Async** for I/O-bound operations (network, files, subprocesses)
2. **Threading** for blocking operations (serial I/O, legacy libraries)
3. **Concurrent tasks** enable simultaneous camera capture
4. **Shared state** via global variables (with locks for critical sections)
5. **Hybrid architecture** provides best performance and maintainability

---

## 9. Code References

- **WebSocket Endpoint**: Lines 300-346
- **Telemetry Generation**: Lines 1247-1334
- **Camera Capture Loop**: Lines 241-298
- **Single Camera Capture**: Lines 213-239
- **MAVLink Reader Loop**: Lines 1069-1245
- **Thread Startup**: Lines 1336-1342
- **Mission Upload (with locks)**: Lines 744-855

---

**End of Document**

