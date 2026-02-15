# Server1.py Comprehensive Implementation Guide

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Core Components](#core-components)
3. [MAVLink Integration](#mavlink-integration)
4. [WebSocket Communication](#websocket-communication)
5. [Mission Management](#mission-management)
6. [Telemetry System](#telemetry-system)
7. [Camera Control](#camera-control)
8. [Battery Monitoring](#battery-monitoring)
9. [Threading & Concurrency](#threading--concurrency)
10. [Error Handling & Recovery](#error-handling--recovery)
11. [Function Reference](#function-reference)

---

## Architecture Overview

### What is server1.py?

`server1.py` is a **Python FastAPI server** that acts as a **bridge** between:
- **Mobile App (Frontend)**: Flutter application running on Android/iOS
- **Drone Autopilot**: ArduPilot/PX4 flight controller via MAVLink protocol

### Core Responsibilities

1. **WebSocket Server**: Handles real-time bidirectional communication with mobile app
2. **MAVLink Interface**: Communicates with drone autopilot using MAVLink protocol
3. **Mission Management**: Uploads waypoints, starts/stops missions, monitors progress
4. **Telemetry Streaming**: Reads sensor data from autopilot and broadcasts to clients
5. **Camera Control**: Manages dual-camera capture (RGB + NoIR) during missions
6. **Battery Monitoring**: Tracks battery voltage and triggers RTL when low
7. **State Management**: Maintains mission state, waypoint tracking, connection status

### Technology Stack

- **FastAPI**: Modern Python web framework for async HTTP/WebSocket
- **pymavlink**: Python library for MAVLink protocol communication
- **asyncio**: Asynchronous programming for concurrent operations
- **threading**: Background threads for MAVLink reading
- **rpicam**: Raspberry Pi camera utilities for image capture

---

## Core Components

### 1. Global State Variables

```python
# Mission state
is_mission_active = False          # Is mission currently running?
mission_waypoints = []              # List of waypoints from frontend
current_waypoint_index = 0         # Current waypoint being executed
mission_progress = 0                # Mission completion percentage (0-100)
mission_type = None                 # Mission type: 'inspection', 'dense_inspection', 'spraying', 'dimr'
total_waypoints = 0                 # Total number of waypoints in mission

# Battery monitoring
BATTERY_THRESHOLD = 90.0           # Battery % threshold for RTL (90%)
rtl_triggered_by_battery = False   # Has RTL been triggered by low battery?
battery_voltage_mv = 0             # Battery voltage in millivolts

# Drone telemetry (updated by MAVLink reader)
drone_latitude = 0.0               # Current GPS latitude
drone_longitude = 0.0              # Current GPS longitude
drone_altitude = 0.0               # Current altitude (meters)
drone_speed = 0.0                  # Ground speed (m/s)
drone_heading = 0.0                # Heading (degrees, 0-360)
drone_battery = 100                # Battery percentage (0-100)
drone_spray = 100                  # Spray tank level (0-100)

# Last known good coordinates (fallback if GPS loses fix)
last_good_latitude = None
last_good_longitude = None

# WebSocket clients
connected_clients: List[WebSocket] = []  # List of connected mobile apps

# MAVLink connection
mavlink_master = None               # MAVLink connection object
mavlink_lock = threading.Lock()    # Thread lock for MAVLink operations
mavlink_rx_pause = threading.Event()  # Pause flag for RX loop during mission upload
mavlink_pause_since = 0.0          # Timestamp when pause started

# Camera control
capture_task: asyncio.Task | None = None      # Background capture task
capture_stop_event: asyncio.Event | None = None  # Stop signal for capture loop
capture_frame_counter: int = 0                 # Frame counter for naming
capture_session_counter: int = 0               # Session counter for naming
```

### 2. FastAPI Application

```python
app = FastAPI()  # Creates FastAPI application instance
```

**Endpoints**:
- `GET /status`: Health check endpoint
- `WebSocket /ws/telemetry`: Main WebSocket endpoint for all communication

---

## MAVLink Integration

### What is MAVLink?

**MAVLink** (Micro Air Vehicle Link) is a **lightweight messaging protocol** for communicating with drones and other unmanned vehicles. It's the standard protocol used by ArduPilot, PX4, and other autopilot systems.

### MAVLink Connection Setup

```python
MAVLINK_PORT = "/dev/ttyACM0"  # Serial port (USB connection to Pixhawk)
MAVLINK_BAUD = 115200           # Baud rate (115200 bits/second)
```

### MAVLink Reader Loop

**Purpose**: Continuously reads MAVLink messages from autopilot in a background thread.

**Location**: `_mavlink_reader_loop()` (lines 1069-1245)

**How it works**:

1. **Connection Establishment**:
```python
m = mavutil.mavlink_connection(MAVLINK_PORT, baud=MAVLINK_BAUD, force_mavlink2=True)
m.wait_heartbeat(timeout=10)
```
- Opens serial connection to `/dev/ttyACM0` at 115200 baud
- Waits for autopilot heartbeat (confirms connection)
- Uses MAVLink 2.0 protocol (more efficient than v1.0)

2. **Request Message Streams**:
```python
for msg_id, hz in [
    (MAVLINK_MSG_ID_GLOBAL_POSITION_INT, 10),  # Position updates at 10 Hz
    (MAVLINK_MSG_ID_VFR_HUD, 5),               # HUD data at 5 Hz
    (MAVLINK_MSG_ID_SYS_STATUS, 1),            # System status at 1 Hz
    (MAVLINK_MSG_ID_ATTITUDE, 10),             # Attitude at 10 Hz
    (MAVLINK_MSG_ID_GPS_RAW_INT, 2),           # GPS raw at 2 Hz
]:
    _request_message_interval(m, msg_id, hz, autopilot_comp)
```

**Message Types Explained**:

- **GLOBAL_POSITION_INT**: GPS position, altitude, heading
  - Fields: `lat`, `lon` (degrees × 1e7), `relative_alt` (mm), `hdg` (centidegrees)
  - Update rate: 10 Hz (10 times per second)

- **VFR_HUD**: Vehicle flight report (HUD data)
  - Fields: `groundspeed` (m/s), `heading` (degrees), `alt` (meters)
  - Update rate: 5 Hz

- **SYS_STATUS**: System status (battery, sensors)
  - Fields: `voltage_battery` (millivolts), sensor health flags
  - Update rate: 1 Hz

- **ATTITUDE**: Vehicle attitude (roll, pitch, yaw)
  - Fields: `yaw` (radians), `roll`, `pitch`
  - Update rate: 10 Hz

- **GPS_RAW_INT**: Raw GPS data
  - Fields: `lat`, `lon`, GPS fix quality
  - Update rate: 2 Hz

3. **Message Processing Loop**:
```python
while True:
    # Check if RX is paused (during mission upload)
    if mavlink_rx_pause.is_set():
        time.sleep(0.05)
        continue
    
    # Receive next message (blocking, 0.5s timeout)
    msg = m.recv_match(blocking=True, timeout=0.5)
    
    if not msg:
        continue  # No message received
    
    # Process based on message type
    t = msg.get_type()
    
    if t == "GLOBAL_POSITION_INT":
        # Extract latitude/longitude (convert from degE7 to degrees)
        lat = msg.lat / 1e7
        lon = msg.lon / 1e7
        
        # Validate coordinates
        if -90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0 and not (lat == 0.0 and lon == 0.0):
            drone_latitude = lat
            drone_longitude = lon
            last_good_latitude = lat  # Store as fallback
            last_good_longitude = lon
        
        # Extract altitude (convert from mm to meters)
        if msg.relative_alt is not None:
            drone_altitude = msg.relative_alt / 1000.0
        
        # Extract heading (convert from centidegrees to degrees)
        if msg.hdg not in (None, 65535):
            drone_heading = (msg.hdg / 100.0) % 360.0
    
    elif t == "VFR_HUD":
        # Extract ground speed
        if msg.groundspeed is not None:
            drone_speed = float(msg.groundspeed)
        
        # Extract heading
        if msg.heading is not None:
            drone_heading = float(msg.heading) % 360.0
    
    elif t == "SYS_STATUS":
        # Extract battery voltage
        voltage_mv = msg.voltage_battery
        if voltage_mv is not None and voltage_mv > 0:
            battery_voltage_mv = voltage_mv
            
            # Convert voltage to percentage using LiPo discharge curve
            voltage_v = voltage_mv / 1000.0
            drone_battery = _calculate_battery_percentage(voltage_v)
```

**Why Background Thread?**

- MAVLink reading is **blocking** (waits for messages)
- FastAPI is **async** (non-blocking)
- Running MAVLink reader in a thread prevents blocking the WebSocket server
- Thread runs continuously, updating global state variables

**Error Handling**:
```python
except Exception as e:
    try:
        m.close()  # Close connection
    except Exception:
        pass
    print(f"[MAVLINK] Error: {e}; reconnecting in 2s")
    time.sleep(2)
    continue  # Retry connection
```

---

## WebSocket Communication

### WebSocket Endpoint

**Location**: `websocket_endpoint()` (lines 300-346)

**Purpose**: Handles WebSocket connections from mobile app

**Flow**:

1. **Accept Connection**:
```python
await websocket.accept()
connected_clients.append(websocket)
```

2. **Send Connection Confirmation**:
```python
await websocket.send_json({
    "type": "connection_status",
    "status": "connected",
    "message": "Successfully connected to Agron GCS Server"
})
```

3. **Send Pending Messages**:
```python
pending_messages = _load_pending_messages()
for msg in pending_messages:
    await websocket.send_json(msg)
_clear_pending_messages()
```
- Critical messages (RTL, mission completion) are saved to disk
- If client disconnects and reconnects, pending messages are delivered
- Ensures no critical events are lost

4. **Message Reception Loop**:
```python
while True:
    data = await websocket.receive_text()  # Wait for message
    message = json.loads(data)             # Parse JSON
    await handle_client_message(websocket, message)  # Process message
```

### Client Message Handler

**Location**: `handle_client_message()` (lines 348-859)

**Purpose**: Routes incoming messages to appropriate handlers

**Message Types Handled**:

1. **`upload_mission`**: Upload waypoints to autopilot
2. **`start_mission`**: Start mission execution
3. **`pause_mission`**: Pause active mission
4. **`resume_mission`**: Resume paused mission
5. **`stop_mission`**: Stop mission and trigger RTL
6. **`emergency_return`**: Emergency RTL
7. **`start_capture`**: Start camera capture loop
8. **`stop_capture`**: Stop camera capture loop
9. **`ping`**: Connection validation

---

## Mission Management

### Mission Upload Process

**Location**: `handle_client_message()` → `upload_mission` handler (lines 506-859)

**Purpose**: Converts frontend waypoints to MAVLink mission format and uploads to autopilot

**Step-by-Step Process**:

#### Step 1: Validate Input
```python
if mavutil is None:
    await websocket.send_json({"type": "mission_status", "status": "error", "message": "pymavlink not installed"})
    return

if not mavlink_master:
    await websocket.send_json({"type": "mission_status", "status": "error", "message": "autopilot not connected"})
    return

raw_wps = message.get("waypoints") or []
if not isinstance(raw_wps, list) or len(raw_wps) == 0:
    await websocket.send_json({"type": "mission_status", "status": "error", "message": "no waypoints provided"})
    return
```

#### Step 2: Configure MIS_OPTIONS Parameter
```python
# Check if autopilot is configured to ignore TAKEOFF command
m.mav.param_request_read_send(..., b"MIS_OPTIONS", ...)
pv = m.recv_match(type='PARAM_VALUE', blocking=True, timeout=2)

if pv.param_value & 1:  # Bit 0 = ignore TAKEOFF
    # Clear bit 0 to enable TAKEOFF
    m.mav.param_set_send(..., b"MIS_OPTIONS", new_val, ...)
```

**Why?** Some ArduPilot configurations ignore the TAKEOFF command. This ensures TAKEOFF is executed.

#### Step 3: Build Mission Items

**Mission Structure**:
```
Item 0: LOITER_TIME (3 seconds at first waypoint)
Item 1: TAKEOFF (climb to altitude)
Item 2: WAYPOINT (first waypoint)
Item 3-N: WAYPOINT (remaining waypoints)
Item N+1: RETURN_TO_LAUNCH (RTL)
```

**Code**:
```python
frame = mavutil.mavlink.MAV_FRAME_GLOBAL_RELATIVE_ALT  # Altitude relative to home

# Item 0: Dummy loiter (3 seconds)
wp0_int = mavutil.mavlink.MAVLink_mission_item_int_message(
    m.target_system,
    m.target_component,
    0,  # Sequence number
    frame,
    mavutil.mavlink.MAV_CMD_NAV_LOITER_TIME,  # Command type
    0, 1,  # Auto-continue, current
    3.0, 0, 0, 0,  # Parameters: time (seconds)
    int(first_lat * 1e7),  # Latitude (degrees × 1e7)
    int(first_lon * 1e7),  # Longitude (degrees × 1e7)
    20.0  # Altitude (meters)
)

# Item 1: TAKEOFF
takeoff_int = mavutil.mavlink.MAVLink_mission_item_int_message(
    m.target_system,
    m.target_component,
    1,
    frame,
    mavutil.mavlink.MAV_CMD_NAV_TAKEOFF,
    0, 1,
    0, 0, 0, 0,
    0, 0,  # Lat/lon not used for TAKEOFF
    20.0  # Target altitude
)

# Item 2: First waypoint
wp_first_int = mavutil.mavlink.MAVLink_mission_item_int_message(
    m.target_system,
    m.target_component,
    2,
    frame,
    mavutil.mavlink.MAV_CMD_NAV_WAYPOINT,
    0, 1,
    0, 0, 0, 0,
    int(first_lat * 1e7),
    int(first_lon * 1e7),
    20.0
)

# Remaining waypoints
for wp in raw_wps[1:]:
    lat, lon = _extract_lat_lon(wp)
    wp_int = mavutil.mavlink.MAVLink_mission_item_int_message(...)
    cmds_int.append(wp_int)

# Last: RTL
rtl_int = mavutil.mavlink.MAVLink_mission_item_int_message(
    m.target_system,
    m.target_component,
    seq,
    frame,
    mavutil.mavlink.MAV_CMD_NAV_RETURN_TO_LAUNCH,
    0, 1,
    0, 0, 0, 0,
    0, 0, 0  # RTL doesn't need coordinates
)
```

#### Step 4: Upload to Autopilot

**MAVLink Mission Upload Protocol**:

1. **Pause RX Loop**:
```python
mavlink_rx_pause.set()  # Prevent interference from incoming messages
```

2. **Clear Existing Mission**:
```python
m.mav.mission_clear_all_send(m.target_system, m.target_component)
```

3. **Send Mission Count**:
```python
total = len(cmds_int)
m.mav.mission_count_send(m.target_system, m.target_component, total, 0)
```
- Autopilot responds with `MISSION_REQUEST_INT` for each item

4. **Send Each Mission Item**:
```python
while sent < expected:
    # Wait for autopilot to request next item
    msg_req = m.recv_match(type=['MISSION_REQUEST_INT'], blocking=True, timeout=5)
    idx = msg_req.seq  # Sequence number requested
    
    # Send the requested item
    m.mav.send(cmds_int[idx])
    sent = idx + 1
```

5. **Wait for ACK**:
```python
ack = m.recv_match(type='MISSION_ACK', blocking=True, timeout=5)
if ack.type == mavutil.mavlink.MAV_MISSION_ACCEPTED:
    # Success!
else:
    # Error handling
```

6. **Verify Upload** (Optional):
```python
# Request mission list from autopilot
m.mav.mission_request_list_send(...)
cnt_msg = m.recv_match(type='MISSION_COUNT', blocking=True, timeout=3)

# Read back each item
for i in range(total_rb):
    m.mav.mission_request_int_send(..., i)
    it = m.recv_match(type=['MISSION_ITEM_INT'], blocking=True, timeout=2)
    # Verify item matches what we sent
```

7. **Resume RX Loop**:
```python
mavlink_rx_pause.clear()  # Resume telemetry reading
```

#### Step 5: Confirm to Client
```python
await websocket.send_json({
    "type": "mission_status",
    "status": "uploaded",
    "count": len(cmds_int)
})
```

### Mission Start Process

**Location**: `handle_client_message()` → `start_mission` handler (lines 355-423)

**Purpose**: Arms drone, sets AUTO mode, and starts mission execution

**Step-by-Step**:

1. **Extract Waypoints**:
```python
mission_waypoints = message["waypoints"]
mission_type = message.get("mission_type")
total_waypoints = len(mission_waypoints)

# Extract first waypoint coordinates
if "position" in first_waypoint:
    drone_latitude = first_waypoint["position"]["latitude"]
    drone_longitude = first_waypoint["position"]["longitude"]
```

2. **Initialize Battery Monitoring** (for DIMR missions):
```python
if mission_type == "dimr":
    rtl_triggered_by_battery = False
    print(f"[MISSION] DIMR mission - Battery threshold monitoring ENABLED ({BATTERY_THRESHOLD}%)")
```

3. **Arm Vehicle**:
```python
_arm_vehicle(m, force=True)
armed = _wait_heartbeat_armed(m, timeout_s=8.0)
if not armed:
    raise RuntimeError("Failed to arm vehicle")
```

**Arming Function**:
```python
def _arm_vehicle(m, force=False):
    m.mav.command_long_send(
        m.target_system,
        m.target_component,
        mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM,
        0,
        1,  # Arm (1 = arm, 0 = disarm)
        21196 if force else 0,  # ArduPilot magic number for force arm
        0, 0, 0, 0, 0
    )
```

**Wait for Armed**:
```python
def _wait_heartbeat_armed(m, timeout_s=8.0):
    deadline = time.time() + timeout_s
    flag = mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED
    
    while time.time() < deadline:
        hb = m.recv_match(type='HEARTBEAT', blocking=True, timeout=1)
        if hb and (hb.base_mode & flag):
            return True  # Armed!
    return False  # Timeout
```

4. **Set AUTO Mode**:
```python
_set_mode_auto(m)
```

**Set Mode Function**:
```python
def _set_mode_auto(m):
    try:
        m.set_mode_apm('AUTO')  # ArduPilot-specific helper
    except Exception:
        # Fallback (not consistently supported)
        pass
```

5. **Set Ground Speed**:
```python
default_speed = message.get("defaultSpeed", 5.0)  # m/s
_set_ground_speed(m, speed_mps=default_speed)
```

**Set Speed Function**:
```python
def _set_ground_speed(m, speed_mps):
    m.mav.command_long_send(
        m.target_system,
        m.target_component,
        mavutil.mavlink.MAV_CMD_DO_CHANGE_SPEED,
        0,
        1,  # Speed type: groundspeed
        float(speed_mps),  # Speed in m/s
        -1, 0, 0, 0, 0
    )
    
    # Also set ArduPilot parameter WPNAV_SPEED (cm/s)
    m.mav.param_set_send(
        m.target_system,
        m.target_component,
        b"WPNAV_SPEED",
        float(speed_mps * 100.0),  # Convert m/s to cm/s
        mavutil.mavlink.MAV_PARAM_TYPE_REAL32
    )
```

6. **Start Mission**:
```python
_mission_set_current(m, 0)  # Set current waypoint to 0 (TAKEOFF)
_mission_start(m, 0, 0)     # Start mission from waypoint 0
```

**Mission Start Function**:
```python
def _mission_start(m, first_seq=0, last_seq=0):
    m.mav.command_long_send(
        m.target_system,
        m.target_component,
        mavutil.mavlink.MAV_CMD_MISSION_START,
        0,
        first_seq,  # First waypoint index
        last_seq,   # Last waypoint index (0 = all)
        0, 0, 0, 0, 0
    )
```

7. **Update State and Notify Client**:
```python
is_mission_active = True
await broadcast_message({
    "type": "mission_status",
    "status": "started",
    "mode": "AUTO",
    "target_speed_kmh": 10
})
```

### Mission Stop Process

**Location**: `handle_client_message()` → `stop_mission` handler (lines 439-470)

**Purpose**: Stops mission and triggers Return-to-Launch (RTL)

**Process**:
```python
is_mission_active = False
mission_progress = 0
current_waypoint_index = 0

# Trigger RTL on autopilot
try:
    m.set_mode_apm('RTL')  # ArduPilot-specific
except Exception:
    # Fallback: Send RTL command
    m.mav.command_long_send(
        m.target_system,
        m.target_component,
        mavutil.mavlink.MAV_CMD_NAV_RETURN_TO_LAUNCH,
        0, 0, 0, 0, 0, 0, 0, 0
    )

await broadcast_message({
    "type": "mission_status",
    "status": "stopped"
})
```

---

## Telemetry System

### Telemetry Generation

**Location**: `generate_telemetry()` (lines 1247-1334)

**Purpose**: Periodically broadcasts telemetry data to all connected clients

**Frequency**: 1 Hz (once per second)

**Process**:

1. **Prepare Telemetry Data**:
```python
# Use last known good coordinates if current are zero
lat_out = drone_latitude if drone_latitude not in (None, 0.0) else last_good_latitude
lon_out = drone_longitude if drone_longitude not in (None, 0.0) else last_good_longitude

# Calculate mission progress
if is_mission_active and total_waypoints > 0:
    mission_progress = int((current_waypoint_index / total_waypoints) * 100)

# Convert battery voltage to volts
battery_voltage_v = battery_voltage_mv / 1000.0 if battery_voltage_mv > 0 else 0.0
```

2. **Build Telemetry JSON**:
```python
telemetry = {
    "type": "telemetry",
    "latitude": lat_out,
    "longitude": lon_out,
    "altitude": drone_altitude,
    "speed": drone_speed,
    "heading": drone_heading,
    "batteryPercentage": int(drone_battery),
    "batteryVoltage": round(battery_voltage_v, 2),
    "sprayLevel": int(drone_spray),
    "missionProgress": int(mission_progress),
    "currentWaypointIndex": current_waypoint_index,
    "totalWaypoints": total_waypoints,
    "timestamp": datetime.now().isoformat()
}
```

3. **Battery Threshold Check** (for DIMR missions):
```python
if is_mission_active and mission_type == 'dimr' and not rtl_triggered_by_battery:
    battery_level = float(drone_battery)
    battery_v = battery_voltage_mv / 1000.0
    
    if battery_level < BATTERY_THRESHOLD:  # 90%
        rtl_triggered_by_battery = True
        
        # Trigger RTL on autopilot
        m.set_mode_apm('RTL')
        
        is_mission_active = False
        
        # Create RTL message
        rtl_message = {
            "type": "mission_status",
            "status": "rtl_battery_low",
            "battery": battery_level,
            "batteryVoltage": round(battery_v, 2),
            "currentWaypointIndex": current_waypoint_index,
            "totalWaypoints": total_waypoints,
            "progressPercentage": mission_progress,
            "message": f"RTL triggered: Battery at {battery_level}% ({battery_v:.2f}V)"
        }
        
        # Save to persistent queue
        _save_pending_message(rtl_message)
        
        # Broadcast to clients
        await broadcast_message(rtl_message)
```

4. **Broadcast to All Clients**:
```python
await broadcast_message(telemetry)
await asyncio.sleep(1)  # Wait 1 second before next broadcast
```

### Broadcast Function

**Location**: `broadcast_message()` (lines 861-876)

**Purpose**: Sends message to all connected WebSocket clients

**Process**:
```python
async def broadcast_message(message):
    if not connected_clients:
        return
    
    disconnected = []
    for client in connected_clients:
        try:
            await client.send_json(message)
        except Exception:
            disconnected.append(client)  # Client disconnected
    
    # Remove disconnected clients
    for client in disconnected:
        if client in connected_clients:
            connected_clients.remove(client)
```

**Why try/except?** WebSocket connections can drop unexpectedly. We catch exceptions and remove dead connections.

---

## Camera Control

### Camera Capture System

**Purpose**: Captures RGB and NoIR images simultaneously during missions

**Hardware**: Raspberry Pi with dual cameras (camera 0 = NoIR, camera 1 = RGB)

**Tools Used**: `rpicam-still` (Raspberry Pi camera utility)

### Capture Directory Structure

**Location**: `_compute_capture_dirs()` (lines 179-184)

```python
def _compute_capture_dirs():
    now = datetime.now()
    day = now.day  # 1-31
    mon = now.strftime("%b").lower()  # jan, feb, mar, ...
    base = pathlib.Path(f"/home/agron/{day}-{mon}-data-agron")
    return base / "noir", base / "rgb"
```

**Example**: `/home/agron/15-jan-data-agron/noir/` and `/home/agron/15-jan-data-agron/rgb/`

### Single Capture Function

**Location**: `_capture_once()` (lines 213-239)

**Purpose**: Captures a single image from one camera

**Process**:
```python
async def _capture_once(camera_index: int, output_path: pathlib.Path) -> bool:
    exe = shutil.which("rpicam-still")
    if not exe:
        return False
    
    # Launch rpicam-still subprocess
    proc = await asyncio.create_subprocess_exec(
        exe,
        "--camera", str(camera_index),  # Camera 0 or 1
        "-n",                            # No preview
        "-t", "1",                       # Timeout 1 second
        "--shutter", "300",              # Exposure: 1/1000s
        "-o", str(output_path),          # Output file
        stdout=PIPE, stderr=PIPE
    )
    
    out, err = await proc.communicate()
    
    if proc.returncode != 0:
        return False  # Capture failed
    return True  # Success
```

### Capture Loop

**Location**: `_capture_loop()` (lines 241-298)

**Purpose**: Continuously captures images from both cameras at specified interval

**Process**:

1. **Initialize**:
```python
_ensure_capture_dirs()  # Create directories if needed
await _list_cameras()   # Log connected cameras
```

2. **Capture Loop**:
```python
while not stop_event.is_set():
    # Generate timestamp
    ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:-3]  # Millisecond precision
    
    # Get altitude (integer)
    alt_int = int(math.ceil(float(drone_altitude)))
    
    # Get coordinates
    lat_val = drone_latitude if drone_latitude not in (None, 0.0) else last_good_latitude
    lon_val = drone_longitude if drone_longitude not in (None, 0.0) else last_good_longitude
    
    # Format coordinates
    lat_str = f"{float(lat_val):.5f}"
    lon_str = f"{float(lon_val):.5f}"
    
    # Build filename
    base = f"session_{sess}_{ts}_{frame_no}_{alt_int}_{lat_str}_{lon_str}"
    noir_path = NOIR_DIR / f"{base}_noir.jpg"
    rgb_path = RGB_DIR / f"{base}_rgb.jpg"
    
    # Capture both cameras concurrently
    t1 = asyncio.create_task(_capture_once(0, noir_path))  # NoIR
    t2 = asyncio.create_task(_capture_once(1, rgb_path))  # RGB
    
    # Wait for both to complete (with timeout)
    res1, res2 = await asyncio.wait_for(
        asyncio.gather(t1, t2),
        timeout=max(3.0, interval_seconds)
    )
    
    # Update frame counter
    capture_frame_counter = frame_no
    
    # Wait for next capture interval
    await asyncio.sleep(interval_seconds)
```

**Filename Format**: `session_{session_id}_{timestamp}_{frame}_{altitude}_{lat}_{lon}_{camera}.jpg`

**Example**: `session_1_20240115_103045_123_001_20_24.12345_67.67890_noir.jpg`

### Start Capture Command

**Location**: `handle_client_message()` → `start_capture` handler (lines 481-491)

```python
if msg_type == "start_capture":
    if capture_task and not capture_task.done():
        print("[CAMERA] Capture already running")
    else:
        capture_frame_counter = 0
        capture_session_counter += 1
        capture_stop_event = asyncio.Event()
        capture_task = asyncio.create_task(
            _capture_loop(capture_stop_event, interval_seconds=2.0)
        )
    await broadcast_message({"type": "camera_status", "status": "capture_started"})
```

### Stop Capture Command

**Location**: `handle_client_message()` → `stop_capture` handler (lines 493-504)

```python
if msg_type == "stop_capture":
    if capture_stop_event is not None:
        capture_stop_event.set()  # Signal stop
    
    if capture_task is not None:
        try:
            await asyncio.wait_for(capture_task, timeout=5.0)
        except Exception:
            capture_task.cancel()  # Force cancel if timeout
    
    capture_task = None
    capture_stop_event = None
    await broadcast_message({"type": "camera_status", "status": "capture_stopped"})
```

---

## Battery Monitoring

### Battery Percentage Calculation

**Location**: `_calculate_battery_percentage()` (lines 51-83)

**Purpose**: Converts battery voltage to percentage using LiPo discharge curve

**LiPo 6S Discharge Curve**:
```python
LIPO_DISCHARGE_CURVE = [
    (25.2, 100),  # Fully charged (4.2V per cell × 6 cells)
    (24.3, 83),   # Good
    (23.4, 67),   # OK
    (22.5, 50),   # Medium
    (21.6, 33),   # Getting low
    (20.7, 17),   # Low
    (19.8, 0),    # Critical (3.3V per cell)
]
```

**Algorithm**:
```python
def _calculate_battery_percentage(voltage_v: float) -> int:
    # Handle out of range
    if voltage_v >= 25.2:
        return 100
    if voltage_v <= 19.8:
        return 0
    
    # Find two points to interpolate between
    for i in range(len(LIPO_DISCHARGE_CURVE) - 1):
        v_high, pct_high = LIPO_DISCHARGE_CURVE[i]
        v_low, pct_low = LIPO_DISCHARGE_CURVE[i + 1]
        
        if v_low <= voltage_v <= v_high:
            # Linear interpolation
            voltage_range = v_high - v_low
            pct_range = pct_high - pct_low
            voltage_offset = voltage_v - v_low
            
            percentage = pct_low + (voltage_offset / voltage_range) * pct_range
            return int(round(percentage))
    
    return 0
```

**Example**:
- Voltage: 24.0V
- Between (24.3, 83%) and (23.4, 67%)
- Interpolation: `67 + ((24.0 - 23.4) / (24.3 - 23.4)) * (83 - 67) = 77.67%`
- Result: **78%**

### Battery Threshold Monitoring

**Location**: `generate_telemetry()` → Battery check (lines 1279-1328)

**Purpose**: Monitors battery level during DIMR missions and triggers RTL if below threshold

**Process**:
```python
if is_mission_active and mission_type == 'dimr' and not rtl_triggered_by_battery:
    battery_level = float(drone_battery)
    battery_v = battery_voltage_mv / 1000.0
    
    if battery_level < BATTERY_THRESHOLD:  # 90%
        rtl_triggered_by_battery = True
        
        # Trigger RTL
        m.set_mode_apm('RTL')
        
        is_mission_active = False
        
        # Save and broadcast RTL message
        rtl_message = {...}
        _save_pending_message(rtl_message)
        await broadcast_message(rtl_message)
```

**Why 90%?** DIMR (Dense Inspection Mission Return) missions are long-duration. Triggering RTL at 90% ensures sufficient battery for safe return.

---

## Threading & Concurrency

### Thread Architecture

**Main Thread**: FastAPI event loop (handles WebSocket connections)

**Background Thread**: MAVLink reader loop (reads telemetry from autopilot)

**Async Tasks**: Telemetry generation, camera capture

### Thread Safety

**MAVLink Lock**:
```python
mavlink_lock = threading.Lock()

# Usage during mission upload
with mavlink_lock:
    m.mav.mission_clear_all_send(...)
    # ... mission upload operations ...
```

**Why?** Prevents race conditions when multiple operations access MAVLink connection simultaneously.

**RX Pause Event**:
```python
mavlink_rx_pause = threading.Event()

# During mission upload
mavlink_rx_pause.set()  # Pause RX loop
# ... upload mission ...
mavlink_rx_pause.clear()  # Resume RX loop
```

**Why?** Mission upload requires exclusive access to MAVLink connection. Pausing RX loop prevents interference from incoming telemetry messages.

### Startup Sequence

**Location**: `startup_event()` (lines 1336-1342)

```python
@app.on_event("startup")
async def startup_event():
    # Start MAVLink reader in background thread
    threading.Thread(target=_mavlink_reader_loop, daemon=True).start()
    
    # Start telemetry generation task
    asyncio.create_task(generate_telemetry())
```

**Order**:
1. MAVLink reader thread starts (connects to autopilot)
2. Telemetry generation task starts (broadcasts data)
3. WebSocket server ready (accepts client connections)

---

## Error Handling & Recovery

### MAVLink Connection Recovery

**Location**: `_mavlink_reader_loop()` → Exception handler (lines 1238-1245)

```python
except Exception as e:
    try:
        m.close()  # Close broken connection
    except Exception:
        pass
    print(f"[MAVLINK] Error: {e}; reconnecting in 2s")
    time.sleep(2)
    continue  # Retry connection
```

**Behavior**: Automatically reconnects if connection drops.

### Persistent Message Queue

**Purpose**: Ensures critical messages (RTL, mission completion) are not lost if client disconnects

**Location**: `_save_pending_message()`, `_load_pending_messages()`, `_clear_pending_messages()` (lines 86-145)

**Process**:
```python
def _save_pending_message(message):
    with pending_messages_lock:
        messages = []
        if pending_messages_file.exists():
            with open(pending_messages_file, 'r') as f:
                messages = json.load(f)
        
        message['saved_at'] = datetime.now().isoformat()
        messages.append(message)
        
        with open(pending_messages_file, 'w') as f:
            json.dump(messages, f, indent=2)
```

**Usage**:
- Save RTL message when battery low
- On client reconnect, load and send pending messages
- Clear after successful delivery

### WebSocket Error Handling

**Location**: `broadcast_message()` (lines 861-876)

```python
disconnected = []
for client in connected_clients:
    try:
        await client.send_json(message)
    except Exception:
        disconnected.append(client)  # Client disconnected

# Remove dead connections
for client in disconnected:
    if client in connected_clients:
        connected_clients.remove(client)
```

**Behavior**: Automatically removes disconnected clients from list.

---

## Function Reference

### MAVLink Functions

#### `_request_message_interval(m, msg_id, hz, target_comp)`
**Purpose**: Request autopilot to send specific message at specified rate
**Parameters**:
- `m`: MAVLink connection
- `msg_id`: MAVLink message ID
- `hz`: Frequency (messages per second)
- `target_comp`: Target component ID

#### `_arm_vehicle(m, force=False)`
**Purpose**: Arm the vehicle (enable motors)
**Parameters**:
- `m`: MAVLink connection
- `force`: Use force arm (bypass safety checks)

#### `_wait_heartbeat_armed(m, timeout_s=8.0)`
**Purpose**: Wait for vehicle to become armed
**Returns**: `True` if armed, `False` if timeout

#### `_set_mode_auto(m)`
**Purpose**: Set autopilot to AUTO mode (mission execution)

#### `_set_mode_guided(m)`
**Purpose**: Set autopilot to GUIDED mode (manual control)

#### `_set_ground_speed(m, speed_mps)`
**Purpose**: Set vehicle ground speed
**Parameters**: `speed_mps`: Speed in meters per second

#### `_mission_start(m, first_seq=0, last_seq=0)`
**Purpose**: Start mission execution
**Parameters**:
- `first_seq`: First waypoint index
- `last_seq`: Last waypoint index (0 = all)

#### `_mission_set_current(m, seq)`
**Purpose**: Set current waypoint index
**Parameters**: `seq`: Waypoint sequence number

#### `_wait_altitude_reached(m, target_alt_m, timeout_s=20.0)`
**Purpose**: Wait for vehicle to reach target altitude
**Returns**: `True` if reached, `False` if timeout

#### `_cmd_name(cmd_id)`
**Purpose**: Convert MAVLink command ID to human-readable name
**Example**: `16` → `"MAV_CMD_NAV_WAYPOINT"`

### Utility Functions

#### `_extract_lat_lon(obj)`
**Purpose**: Extract latitude/longitude from waypoint object
**Handles**: Both `{"position": {"latitude": ..., "longitude": ...}}` and `{"latitude": ..., "longitude": ...}` formats
**Returns**: `(lat, lon)` tuple or `(None, None)` if invalid

#### `_coerce_float(value)`
**Purpose**: Convert value to float (handles int, float, string)
**Returns**: `float` or `None` if conversion fails

#### `_calculate_battery_percentage(voltage_v)`
**Purpose**: Convert battery voltage to percentage using LiPo discharge curve
**Returns**: Integer percentage (0-100)

### Camera Functions

#### `_compute_capture_dirs()`
**Purpose**: Compute capture directory paths based on current date
**Returns**: `(noir_dir, rgb_dir)` tuple

#### `_ensure_capture_dirs()`
**Purpose**: Create capture directories if they don't exist

#### `_list_cameras()`
**Purpose**: List connected cameras using `rpicam-hello`

#### `_capture_once(camera_index, output_path)`
**Purpose**: Capture single image from specified camera
**Returns**: `True` if success, `False` if failure

#### `_capture_loop(stop_event, interval_seconds=0.5)`
**Purpose**: Continuously capture images from both cameras
**Parameters**:
- `stop_event`: `asyncio.Event` to signal stop
- `interval_seconds`: Time between captures

### Message Queue Functions

#### `_save_pending_message(message)`
**Purpose**: Save critical message to persistent queue

#### `_load_pending_messages()`
**Purpose**: Load all pending messages from queue
**Returns**: List of messages

#### `_clear_pending_messages()`
**Purpose**: Clear all pending messages after delivery

---

## Summary

`server1.py` is a **sophisticated bridge** between mobile app and drone autopilot:

1. **WebSocket Server**: Handles real-time communication with mobile app
2. **MAVLink Interface**: Communicates with ArduPilot/PX4 autopilot
3. **Mission Management**: Uploads waypoints, starts/stops missions
4. **Telemetry Streaming**: Broadcasts real-time drone data
5. **Camera Control**: Manages dual-camera capture during missions
6. **Battery Monitoring**: Tracks battery and triggers RTL when low
7. **Error Recovery**: Handles disconnections and reconnects automatically

**Key Technologies**:
- **FastAPI**: Async web framework
- **pymavlink**: MAVLink protocol library
- **asyncio**: Async programming
- **threading**: Background MAVLink reading
- **rpicam**: Raspberry Pi camera utilities

**Architecture**:
- **Main Thread**: FastAPI event loop (WebSocket server)
- **Background Thread**: MAVLink reader (telemetry reading)
- **Async Tasks**: Telemetry generation, camera capture

This architecture ensures **low latency**, **real-time updates**, and **robust error handling** for safe drone operations.







