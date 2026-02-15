# Frontend-Backend Integration Guide

## Overview

The Agron Ground Control Station (GCS) consists of:
- **Frontend**: Flutter mobile application (Android/iOS)
- **Backend**: Python FastAPI server running on Raspberry Pi
- **Communication**: WebSocket (primary) and Socket.IO (legacy) protocols
- **Autopilot**: MAVLink protocol for drone control (ArduPilot/PX4)

---

## 1. Communication Architecture

### 1.1 Protocols Used

#### **WebSocket (Primary)**
- **Endpoint**: `ws://<IP>:5001/ws/telemetry`
- **Library**: `web_socket_channel` (Flutter), `FastAPI WebSocket` (Python)
- **Purpose**: Real-time bidirectional communication
- **Features**:
  - Full-duplex communication
  - Low latency
  - Persistent connection
  - Automatic reconnection support

#### **Socket.IO (Legacy)**
- **Endpoint**: `http://<IP>:5000`
- **Library**: `socket_io_client` (Flutter), `python-socketio` (Python)
- **Purpose**: Fallback communication method
- **Features**:
  - Event-based messaging
  - Automatic reconnection
  - Transport fallback (WebSocket → polling)

#### **HTTP REST**
- **Endpoint**: `http://<IP>:5001/status`
- **Purpose**: Health checks and connection validation
- **Method**: GET request

---

## 2. Connection Establishment

### 2.1 Frontend Connection Flow

```dart
// Location: lib/services/drone_service.dart

// Step 1: User provides IP address
connectToTelemetryWs("192.168.4.1")  // or connectToDrone() for Socket.IO

// Step 2: Validate server exists (HTTP health check)
GET http://192.168.4.1:5001/status
Response: {"status": "running", "clients": 0}

// Step 3: Establish WebSocket connection
WebSocketChannel.connect("ws://192.168.4.1:5001/ws/telemetry")

// Step 4: Listen for connection confirmation
Message received: {
  "type": "connection_status",
  "status": "connected",
  "message": "Successfully connected to Agron GCS Server"
}

// Step 5: Start connection validation (ping every 10 seconds)
Timer.periodic(Duration(seconds: 10), () {
  send({"type": "ping"})
})
```

### 2.2 Backend Connection Handling

```python
# Location: server1.py

@app.websocket("/ws/telemetry")
async def websocket_endpoint(websocket: WebSocket):
    # Step 1: Accept WebSocket handshake
    await websocket.accept()
    
    # Step 2: Add client to connected clients list
    connected_clients.append(websocket)
    
    # Step 3: Send connection confirmation
    await websocket.send_json({
        "type": "connection_status",
        "status": "connected",
        "message": "Successfully connected to Agron GCS Server"
    })
    
    # Step 4: Send any pending critical messages (RTL, mission status)
    pending_messages = _load_pending_messages()
    for msg in pending_messages:
        await websocket.send_json(msg)
    
    # Step 5: Listen for client messages
    while True:
        data = await websocket.receive_text()
        message = json.loads(data)
        await handle_client_message(websocket, message)
```

### 2.3 Connection Persistence

**Frontend (SharedPreferences)**:
- Saves last successful IP address: `last_connection_ip`
- Saves connection type: `last_connection_type` ("websocket" or "socket_io")
- Used for auto-reconnect after disconnection

**Backend**:
- Maintains list of connected clients: `connected_clients: List[WebSocket]`
- Tracks client state in memory
- No persistent storage (stateless)

---

## 3. Message Types and Formats

### 3.1 Client → Server Messages

#### **Connection Messages**

| Message Type | Purpose | Payload |
|-------------|---------|---------|
| `ping` | Connection validation | `{"type": "ping"}` |

#### **Mission Control Messages**

| Message Type | Purpose | Payload |
|-------------|---------|---------|
| `upload_mission` | Upload waypoints to autopilot | See Mission Upload Format |
| `start_mission` | Begin mission execution | See Mission Start Format |
| `pause_mission` | Pause active mission | `{"type": "pause_mission"}` |
| `resume_mission` | Resume paused mission | `{"type": "resume_mission"}` |
| `stop_mission` | Stop mission and RTL | `{"type": "stop_mission"}` |
| `emergency_return` | Emergency RTL | `{"type": "emergency_return"}` |

#### **Camera Control Messages**

| Message Type | Purpose | Payload |
|-------------|---------|---------|
| `start_capture` | Start continuous capture | `{"type": "start_capture"}` |
| `stop_capture` | Stop continuous capture | `{"type": "stop_capture"}` |

### 3.2 Server → Client Messages

#### **Connection Status**

```json
{
  "type": "connection_status",
  "status": "connected",
  "message": "Successfully connected to Agron GCS Server"
}
```

#### **Telemetry Data**

```json
{
  "type": "telemetry",
  "latitude": 24.12345,
  "longitude": 67.67890,
  "altitude": 20.5,
  "speed": 2.3,
  "heading": 180.0,
  "batteryPercentage": 85,
  "batteryVoltage": 24.2,
  "sprayLevel": 75,
  "missionProgress": 45,
  "currentWaypointIndex": 12,
  "totalWaypoints": 27,
  "timestamp": "2024-01-15T10:30:45.123Z"
}
```

#### **Mission Status**

```json
{
  "type": "mission_status",
  "status": "started|paused|resumed|stopped|uploaded|rtl_battery_low|error",
  "mode": "AUTO",
  "target_speed_kmh": 10,
  "count": 27,
  "message": "Optional error message"
}
```

#### **Camera Status**

```json
{
  "type": "camera_status",
  "status": "capture_started|capture_stopped"
}
```

#### **Pong Response**

```json
{
  "type": "pong",
  "timestamp": "2024-01-15T10:30:45.123Z"
}
```

---

## 4. Mission Upload Flow

### 4.1 Frontend Mission Preparation

```dart
// Location: lib/services/drone_service.dart

// Step 1: User selects waypoints on map
List<LatLng> userPoints = [point1, point2, point3, ...];

// Step 2: Build effective waypoints based on mission type
List<MissionWaypoint> effectiveWaypoints = _buildEffectiveWaypoints(mission);

// For "inspection": Compute convex hull
if (missionType == 'inspection') {
    List<LatLng> hull = _computeConvexHull(userPoints);
    effectiveWaypoints = hull.map((p) => MissionWaypoint(...)).toList();
}

// For "dense_inspection": Generate coverage path
if (missionType == 'dense_inspection') {
    List<LatLng> densePath = _generateDensePath(hull, altitude);
    // Simplify path (remove intermediate points on straight segments)
    densePath = _simplifyPath(densePath);
    effectiveWaypoints = densePath.map((p) => MissionWaypoint(...)).toList();
}

// Step 3: Convert to JSON
Map<String, dynamic> message = {
    'type': 'upload_mission',
    'waypoints': effectiveWaypoints.map((w) => w.toJson()).toList(),
    'defaultAltitude': 20.0,
    'defaultSpeed': 5.0,
    'mission_type': 'dense_inspection'
};

// Step 4: Send via WebSocket
_wsChannel.sink.add(json.encode(message));
```

### 4.2 Backend Mission Processing

```python
# Location: server1.py

async def handle_client_message(websocket, message):
    if message["type"] == "upload_mission":
        # Step 1: Extract waypoints
        raw_wps = message.get("waypoints", [])
        mission_type = message.get("mission_type")
        default_altitude = message.get("defaultAltitude", 20.0)
        default_speed = message.get("defaultSpeed", 5.0)
        
        # Step 2: Build MAVLink mission items
        cmds_int = []
        
        # Item 0: Dummy loiter (3 seconds at first waypoint)
        wp0 = MAVLink_mission_item_int_message(
            target_system, target_component, 0,
            MAV_FRAME_GLOBAL_RELATIVE_ALT,
            MAV_CMD_NAV_LOITER_TIME,
            0, 1, 3.0, 0, 0, 0,
            int(first_lat * 1e7), int(first_lon * 1e7), 20.0
        )
        cmds_int.append(wp0)
        
        # Item 1: TAKEOFF command
        takeoff = MAVLink_mission_item_int_message(
            target_system, target_component, 1,
            MAV_FRAME_GLOBAL_RELATIVE_ALT,
            MAV_CMD_NAV_TAKEOFF,
            0, 1, 0, 0, 0, 0,
            0, 0, default_altitude
        )
        cmds_int.append(takeoff)
        
        # Item 2: First waypoint (repeat)
        wp_first = MAVLink_mission_item_int_message(...)
        cmds_int.append(wp_first)
        
        # Items 3-N: Remaining waypoints
        for wp in raw_wps[1:]:
            lat, lon = extract_lat_lon(wp)
            waypoint = MAVLink_mission_item_int_message(
                target_system, target_component, seq,
                MAV_FRAME_GLOBAL_RELATIVE_ALT,
                MAV_CMD_NAV_WAYPOINT,
                0, 1, 0, 0, 0, 0,
                int(lat * 1e7), int(lon * 1e7), default_altitude
            )
            cmds_int.append(waypoint)
            seq += 1
        
        # Last: RTL command
        rtl = MAVLink_mission_item_int_message(
            target_system, target_component, seq,
            MAV_FRAME_GLOBAL_RELATIVE_ALT,
            MAV_CMD_NAV_RETURN_TO_LAUNCH,
            0, 1, 0, 0, 0, 0, 0, 0, 0
        )
        cmds_int.append(rtl)
        
        # Step 3: Upload to autopilot via MAVLink
        # Clear existing mission
        m.mav.mission_clear_all_send(...)
        
        # Send mission count
        m.mav.mission_count_send(..., len(cmds_int), 0)
        
        # Send each mission item (wait for MISSION_REQUEST_INT)
        for idx in range(len(cmds_int)):
            req = m.recv_match(type='MISSION_REQUEST_INT', blocking=True)
            m.mav.send(cmds_int[idx])
        
        # Wait for MISSION_ACK
        ack = m.recv_match(type='MISSION_ACK', blocking=True)
        
        # Step 4: Confirm to client
        await websocket.send_json({
            "type": "mission_status",
            "status": "uploaded",
            "count": len(cmds_int)
        })
```

### 4.3 Mission Start Flow

```dart
// Frontend: lib/services/drone_service.dart

Future<void> startMission(Mission mission) async {
    // Step 1: Build effective waypoints (same as upload)
    List<MissionWaypoint> effectiveWaypoints = _buildEffectiveWaypoints(mission);
    
    // Step 2: Send start command
    Map<String, dynamic> message = {
        'type': 'start_mission',
        'waypoints': effectiveWaypoints.map((w) => w.toJson()).toList(),
        'defaultAltitude': mission.defaultAltitude,
        'defaultSpeed': mission.defaultSpeed,
        'mission_type': _selectedMissionType
    };
    
    _wsChannel.sink.add(json.encode(message));
}
```

```python
# Backend: server1.py

if message["type"] == "start_mission":
    # Step 1: Extract waypoints and mission parameters
    mission_waypoints = message["waypoints"]
    mission_type = message.get("mission_type")
    
    # Step 2: Arm vehicle
    _arm_vehicle(m, force=True)
    _wait_heartbeat_armed(m, timeout_s=8.0)
    
    # Step 3: Set AUTO mode
    _set_mode_auto(m)
    
    # Step 4: Set ground speed
    default_speed = message.get("defaultSpeed", 5.0)
    _set_ground_speed(m, speed_mps=default_speed / 3.6)  # km/h to m/s
    
    # Step 5: Start mission at waypoint 0
    _mission_set_current(m, 0)
    _mission_start(m, 0, 0)
    
    # Step 6: Notify client
    await broadcast_message({
        "type": "mission_status",
        "status": "started",
        "mode": "AUTO",
        "target_speed_kmh": default_speed * 3.6
    })
```

---

## 5. Telemetry Streaming

### 5.1 Backend Telemetry Generation

```python
# Location: server1.py

async def generate_telemetry():
    """Broadcast telemetry every 1 second"""
    while True:
        # Read from MAVLink (updated by _mavlink_reader_loop)
        telemetry = {
            "type": "telemetry",
            "latitude": drone_latitude,
            "longitude": drone_longitude,
            "altitude": drone_altitude,
            "speed": drone_speed,
            "heading": drone_heading,
            "batteryPercentage": drone_battery,
            "batteryVoltage": battery_voltage_mv / 1000.0,
            "sprayLevel": drone_spray,
            "missionProgress": mission_progress,
            "currentWaypointIndex": current_waypoint_index,
            "totalWaypoints": total_waypoints,
            "timestamp": datetime.now().isoformat()
        }
        
        # Broadcast to all connected clients
        await broadcast_message(telemetry)
        await asyncio.sleep(1)
```

### 5.2 MAVLink Data Reading

```python
# Location: server1.py

def _mavlink_reader_loop():
    """Background thread reading MAVLink messages"""
    m = mavutil.mavlink_connection("/dev/ttyACM0", baud=115200)
    m.wait_heartbeat()
    
    # Request message streams
    _request_message_interval(m, MAVLINK_MSG_ID_GLOBAL_POSITION_INT, 10)
    _request_message_interval(m, MAVLINK_MSG_ID_VFR_HUD, 5)
    _request_message_interval(m, MAVLINK_MSG_ID_SYS_STATUS, 1)
    
    while True:
        msg = m.recv_match(blocking=True, timeout=0.5)
        
        if msg.get_type() == "GLOBAL_POSITION_INT":
            drone_latitude = msg.lat / 1e7
            drone_longitude = msg.lon / 1e7
            drone_altitude = msg.relative_alt / 1000.0
            drone_heading = (msg.hdg / 100.0) % 360.0
        
        elif msg.get_type() == "VFR_HUD":
            drone_speed = msg.groundspeed
            drone_heading = msg.heading % 360.0
        
        elif msg.get_type() == "SYS_STATUS":
            battery_voltage_mv = msg.voltage_battery
            drone_battery = _calculate_battery_percentage(voltage_mv / 1000.0)
```

### 5.3 Frontend Telemetry Reception

```dart
// Location: lib/services/drone_service.dart

_wsSubscription = _wsChannel.stream.listen((message) {
    Map<String, dynamic> data = json.decode(message);
    
    if (data['type'] == 'telemetry') {
        // Step 1: Parse telemetry
        Telemetry telemetry = Telemetry.fromJson(data);
        
        // Step 2: Update internal state
        _telemetryController.add(telemetry);
        
        // Step 3: Track mission progress
        if (_isMissionActive) {
            _currentWaypointIndex = data['currentWaypointIndex'] ?? 0;
            _totalWaypoints = data['totalWaypoints'] ?? 0;
            
            // Update mission progress in storage
            _missionStorage.updateMissionProgress(
                _currentMission.id,
                progressPercentage,
                _currentWaypointIndex
            );
        }
        
        // Step 4: Persist last known position
        _persistLastKnownDronePosition(telemetry);
        
        // Step 5: Notify UI listeners
        notifyListeners();
    }
});
```

### 5.4 UI Telemetry Display

```dart
// Location: lib/widgets/telemetry_panel.dart

StreamBuilder<Telemetry>(
    stream: droneService.telemetryStream,
    builder: (context, snapshot) {
        if (snapshot.hasData) {
            Telemetry telemetry = snapshot.data!;
            
            // Display actual values during mission
            if (droneService.isMissionActive) {
                return _buildTelemetryItem(
                    icon: Icons.altitude,
                    label: "Altitude",
                    value: "${telemetry.altitude.toStringAsFixed(1)} m"
                );
            } else {
                // Display target/default values when idle
                return _buildEditableTelemetryItem(
                    icon: Icons.altitude,
                    label: "Altitude",
                    currentValue: telemetry.altitude,
                    targetValue: droneService.targetAltitude,
                    onTap: () => _showEditDialog(context, "Altitude")
                );
            }
        }
        return CircularProgressIndicator();
    }
)
```

---

## 6. Auto-Reconnection Mechanism

### 6.1 Frontend Reconnection Logic

```dart
// Location: lib/services/drone_service.dart

void _scheduleReconnect() {
    if (_userInitiatedDisconnect) return;  // Don't reconnect if user disconnected
    
    _reconnectTimer = Timer(Duration(seconds: 5), () async {
        // Step 1: Load saved IP from SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        final savedIp = prefs.getString('last_connection_ip');
        final savedType = prefs.getString('last_connection_type');
        
        if (savedIp == null) return;
        
        // Step 2: Reconnect using saved connection type
        if (savedType == 'websocket') {
            connectToTelemetryWs(savedIp);
        } else {
            connectToDrone(savedIp);
        }
    });
}
```

### 6.2 Connection Validation

```dart
// Frontend: Ping every 10 seconds to validate connection

void _startConnectionValidation() {
    _connectionValidationTimer = Timer.periodic(Duration(seconds: 10), (timer) {
        if (!_isConnected) {
            timer.cancel();
            return;
        }
        
        // Send ping
        _wsChannel.sink.add(json.encode({'type': 'ping'}));
    });
}
```

```python
# Backend: Respond to ping

if message["type"] == "ping":
    await websocket.send_json({
        "type": "pong",
        "timestamp": datetime.now().isoformat()
    })
```

---

## 7. Camera Control Integration

### 7.1 Frontend Camera Commands

```dart
// Location: lib/services/drone_service.dart

Future<void> sendCaptureCommand(String command) async {
    Map<String, dynamic> message = {'type': command};
    _wsChannel.sink.add(json.encode(message));
}

// Usage:
await droneService.sendCaptureCommand('start_capture');
await droneService.sendCaptureCommand('stop_capture');
```

### 7.2 Backend Camera Handling

```python
# Location: server1.py

if message["type"] == "start_capture":
    # Step 1: Initialize capture session
    capture_session_counter += 1
    capture_frame_counter = 0
    capture_stop_event = asyncio.Event()
    
    # Step 2: Start capture loop (background task)
    capture_task = asyncio.create_task(
        _capture_loop(capture_stop_event, interval_seconds=2.0)
    )
    
    # Step 3: Notify client
    await broadcast_message({
        "type": "camera_status",
        "status": "capture_started"
    })

async def _capture_loop(stop_event, interval_seconds=0.5):
    """Capture RGB and NoIR images every 2 seconds"""
    while not stop_event.is_set():
        # Generate timestamp
        ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:-3]
        
        # Build file paths
        base = f"session_{sess}_{ts}_{frame_no}_{alt}_{lat}_{lon}"
        noir_path = NOIR_DIR / f"{base}_noir.jpg"
        rgb_path = RGB_DIR / f"{base}_rgb.jpg"
        
        # Capture both cameras concurrently
        t1 = asyncio.create_task(_capture_once(0, noir_path))  # NoIR
        t2 = asyncio.create_task(_capture_once(1, rgb_path))   # RGB
        await asyncio.gather(t1, t2)
        
        # Wait for next capture interval
        await asyncio.sleep(interval_seconds)
```

---

## 8. Error Handling

### 8.1 Connection Errors

**Frontend**:
```dart
_wsChannel.stream.listen(
    (message) { /* handle message */ },
    onError: (error) {
        _isConnected = false;
        _connectionError = 'WS error: $error';
        notifyListeners();
        _scheduleReconnect();  // Auto-reconnect after 5 seconds
    },
    onDone: () {
        _isConnected = false;
        _scheduleReconnect();
    }
);
```

**Backend**:
```python
try:
    await websocket.send_json(message)
except Exception as e:
    # Remove disconnected client
    if websocket in connected_clients:
        connected_clients.remove(websocket)
```

### 8.2 Mission Upload Errors

```python
# Backend: server1.py

try:
    # Upload mission to autopilot
    m.mav.mission_count_send(...)
    # ... upload process ...
except Exception as exc:
    await websocket.send_json({
        "type": "mission_status",
        "status": "error",
        "message": str(exc)
    })
```

### 8.3 Critical Message Queue

```python
# Backend: server1.py

# Save critical messages (RTL, mission completion) to disk
def _save_pending_message(message):
    messages = []
    if pending_messages_file.exists():
        with open(pending_messages_file, 'r') as f:
            messages = json.load(f)
    messages.append(message)
    with open(pending_messages_file, 'w') as f:
        json.dump(messages, f)

# On client connect, send pending messages
pending_messages = _load_pending_messages()
for msg in pending_messages:
    await websocket.send_json(msg)
_clear_pending_messages()
```

---

## 9. Data Flow Diagrams

### 9.1 Mission Upload Flow

```
[Frontend]                    [Backend]                    [Autopilot]
    |                             |                             |
    |-- upload_mission ---------->|                             |
    |                             |-- mission_clear_all ------->|
    |                             |<-- MISSION_ACK ------------|
    |                             |                             |
    |                             |-- mission_count_send ------>|
    |                             |<-- MISSION_REQUEST_INT ----|
    |                             |                             |
    |                             |-- mission_item_int (0) ---->|
    |                             |<-- MISSION_REQUEST_INT ----|
    |                             |                             |
    |                             |-- mission_item_int (1) ---->|
    |                             |<-- MISSION_REQUEST_INT ----|
    |                             |                             |
    |                             |-- mission_item_int (N) ---->|
    |                             |<-- MISSION_ACK ------------|
    |                             |                             |
    |<-- mission_status:uploaded -|                             |
```

### 9.2 Telemetry Streaming Flow

```
[Autopilot]                    [Backend]                    [Frontend]
    |                             |                             |
    |-- GLOBAL_POSITION_INT ----->|                             |
    |                             |-- Update drone_latitude     |
    |                             |-- Update drone_longitude   |
    |                             |-- Update drone_altitude     |
    |                             |                             |
    |-- VFR_HUD ----------------->|                             |
    |                             |-- Update drone_speed        |
    |                             |-- Update drone_heading      |
    |                             |                             |
    |-- SYS_STATUS -------------->|                             |
    |                             |-- Update battery_voltage     |
    |                             |-- Calculate battery %        |
    |                             |                             |
    |                             |-- generate_telemetry()      |
    |                             |-- broadcast_message()      |
    |                             |                             |
    |                             |-- telemetry --------------->|
    |                             |                             |
    |                             |                             |-- Parse JSON
    |                             |                             |-- Update UI
    |                             |                             |-- Save position
```

### 9.3 Mission Start Flow

```
[Frontend]                    [Backend]                    [Autopilot]
    |                             |                             |
    |-- start_mission ----------->|                             |
    |                             |-- _arm_vehicle() ---------->|
    |                             |<-- HEARTBEAT (armed) -------|
    |                             |                             |
    |                             |-- _set_mode_auto() -------->|
    |                             |<-- MODE (AUTO) ------------|
    |                             |                             |
    |                             |-- _set_ground_speed() ----->|
    |                             |                             |
    |                             |-- _mission_set_current(0) ->|
    |                             |-- _mission_start() --------->|
    |                             |                             |
    |<-- mission_status:started ---|                             |
    |                             |                             |
    |                             |<-- MISSION_CURRENT --------|
    |                             |-- Update current_waypoint_index
    |                             |                             |
    |                             |-- telemetry (with progress) |
    |<-- telemetry ----------------|                             |
```

---

## 10. Key Integration Points

### 10.1 Waypoint Format Conversion

**Frontend Format**:
```json
{
  "position": {
    "latitude": 24.12345,
    "longitude": 67.67890
  },
  "altitude": 20.0,
  "sprayRate": 0.0,
  "sprayEnabled": true
}
```

**MAVLink Format**:
```python
MAVLink_mission_item_int_message(
    target_system, target_component, seq,
    MAV_FRAME_GLOBAL_RELATIVE_ALT,
    MAV_CMD_NAV_WAYPOINT,
    0, 1, 0, 0, 0, 0,
    int(lat * 1e7),  # Latitude in degrees * 1e7
    int(lon * 1e7),  # Longitude in degrees * 1e7
    altitude         # Altitude in meters
)
```

### 10.2 Coordinate System

- **Frontend**: Decimal degrees (e.g., `24.12345`, `67.67890`)
- **MAVLink**: Integer degrees × 1e7 (e.g., `241234500`, `676789000`)
- **Conversion**: `lat_int = int(lat_deg * 1e7)`, `lat_deg = lat_int / 1e7`

### 10.3 Altitude Reference

- **Frame**: `MAV_FRAME_GLOBAL_RELATIVE_ALT`
- **Meaning**: Altitude relative to home position (not sea level)
- **Unit**: Meters

### 10.4 Speed Units

- **Frontend**: m/s or km/h (user preference)
- **Backend**: m/s (MAVLink standard)
- **Conversion**: `speed_mps = speed_kmh / 3.6`

---

## 11. State Management

### 11.1 Frontend State (DroneService)

```dart
class DroneService extends ChangeNotifier {
    // Connection state
    bool _isConnected = false;
    bool _isConnecting = false;
    String? _connectionError;
    
    // Mission state
    Mission? _currentMission;
    bool _isMissionActive = false;
    bool _isMissionUploaded = false;
    String _selectedMissionType = 'inspection';
    
    // Telemetry
    StreamController<Telemetry> _telemetryController;
    
    // Target parameters
    double? _targetAltitude;
    double? _targetSpeed;
    
    // Progress tracking
    int _currentWaypointIndex = 0;
    int _totalWaypoints = 0;
}
```

### 11.2 Backend State

```python
# Global state variables
is_mission_active = False
mission_waypoints = []
current_waypoint_index = 0
mission_progress = 0
mission_type = None
total_waypoints = 0

# Drone telemetry
drone_latitude = 0.0
drone_longitude = 0.0
drone_altitude = 0.0
drone_speed = 0.0
drone_heading = 0.0
drone_battery = 100
drone_spray = 100

# Connection management
connected_clients: List[WebSocket] = []
mavlink_master = None
```

---

## 12. Security Considerations

### 12.1 Network Security

- **Local Network Only**: Server listens on `0.0.0.0` (all interfaces) but typically accessed via local IP
- **No Authentication**: Currently no authentication (assumes trusted local network)
- **No Encryption**: WebSocket uses `ws://` (not `wss://`)

### 12.2 Data Validation

**Frontend**:
- Validates waypoint coordinates: `-90 <= lat <= 90`, `-180 <= lon <= 180`
- Validates altitude: `>= 0`
- Validates speed: `> 0`

**Backend**:
- Validates JSON structure
- Validates waypoint format
- Validates mission parameters before sending to autopilot

---

## 13. Performance Optimizations

### 13.1 Telemetry Rate

- **MAVLink Request Rate**: 10 Hz for position, 5 Hz for HUD, 1 Hz for status
- **Broadcast Rate**: 1 Hz (1 message per second to clients)
- **Rationale**: Balance between responsiveness and network bandwidth

### 13.2 Waypoint Optimization

- **Path Simplification**: Removes intermediate points on straight segments
- **Algorithm**: `_simplifyPath()` keeps only edge points and direction changes
- **Benefit**: Reduces number of waypoints sent to autopilot (faster upload, less memory)

### 13.3 Connection Pooling

- **Single WebSocket Connection**: One connection per client
- **Broadcast to All**: Server maintains list of connected clients
- **Efficient**: Single telemetry generation loop broadcasts to all clients

---

## 14. Testing and Debugging

### 14.1 Frontend Debugging

```dart
// Enable debug prints
debugPrint('[CONNECTION] Attempting to connect...');
debugPrint('[MISSION] Starting mission with ${waypoints.length} waypoints');
debugPrint('[TELEMETRY] Received: ${telemetry.latitude}, ${telemetry.longitude}');
```

### 14.2 Backend Debugging

```python
# Server logs
print(f"[MISSION] Upload received with {len(raw_wps)} waypoints")
print(f"[MAVLINK] Connected to system {m.target_system}")
print(f"[TELEMETRY] Broadcasting: lat={lat}, lon={lon}, batt={battery}%")
```

### 14.3 Message Logging

- **Frontend**: Logs all sent/received messages via `debugPrint()`
- **Backend**: Logs all client messages and MAVLink communications
- **Waypoint Logging**: Server logs waypoints to file for comparison

---

## 15. Future Enhancements

### 15.1 Planned Features

1. **Authentication**: Add user authentication (JWT tokens)
2. **Encryption**: Use `wss://` (WebSocket Secure) with TLS
3. **Multi-drone Support**: Handle multiple drones simultaneously
4. **Mission Templates**: Pre-defined mission patterns
5. **Real-time Video**: Stream camera feed via WebRTC
6. **Offline Mode**: Queue commands when offline, sync when reconnected

### 15.2 Scalability Improvements

1. **Message Queue**: Use Redis/RabbitMQ for message queuing
2. **Database**: Store mission history in PostgreSQL
3. **Load Balancing**: Multiple server instances behind load balancer
4. **Caching**: Cache frequently accessed data (mission templates, etc.)

---

## Summary

The Agron GCS uses a **WebSocket-based bidirectional communication** architecture between the Flutter frontend and Python FastAPI backend. The backend acts as a **bridge** between the mobile app and the MAVLink autopilot, translating high-level mission commands into low-level MAVLink messages and streaming real-time telemetry back to the app.

**Key Technologies**:
- **WebSocket**: Real-time bidirectional communication
- **MAVLink**: Drone autopilot protocol
- **FastAPI**: Modern Python web framework
- **Flutter**: Cross-platform mobile framework
- **Provider**: State management in Flutter

**Communication Flow**:
1. User creates mission on mobile app
2. App generates waypoints (convex hull or coverage path)
3. App uploads waypoints to server via WebSocket
4. Server converts waypoints to MAVLink format
5. Server uploads mission to autopilot
6. Server streams telemetry from autopilot to app
7. App displays real-time drone status and mission progress

This architecture provides **low latency**, **real-time updates**, and **robust error handling** with automatic reconnection capabilities.







