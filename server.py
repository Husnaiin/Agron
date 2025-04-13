#!/usr/bin/env python3
import os
import time
import json
import random
import math
from datetime import datetime
from flask import Flask, jsonify, request
from flask_cors import CORS
from flask_socketio import SocketIO, emit
import threading

app = Flask(__name__)
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*")

# Mock values for telemetry
mock_latitude = 0.0
mock_longitude = 0.0
mock_altitude = 30.0
mock_speed = 5.0
mock_heading = 0.0
mock_battery = 100
mock_spray = 100
mock_mission_progress = 0
is_mission_active = False
mission_waypoints = []
current_waypoint_index = 0

@app.route('/status')
def status():
    return jsonify({"status": "running"})

@app.route('/connect', methods=['POST'])
def connect():
    data = request.json
    print(f"Connection request from: {data.get('client_id', 'unknown')}")
    return jsonify({"status": "connected", "message": "Successfully connected to Agron GCS Server"})

@socketio.on('connect')
def handle_connect():
    print('Client connected')
    emit('connection_status', {'status': 'connected'})

@socketio.on('disconnect')
def handle_disconnect():
    print('Client disconnected')

@socketio.on('start_mission')
def handle_start_mission(data):
    global is_mission_active, mission_waypoints, mock_latitude, mock_longitude, current_waypoint_index
    print('Starting mission with data:', json.dumps(data, indent=2))
    
    # Extract waypoints from mission data
    if 'waypoints' in data:
        mission_waypoints = data['waypoints']
        if mission_waypoints:
            # Set initial position to first waypoint
            first_waypoint = mission_waypoints[0]
            print(f"First waypoint: {json.dumps(first_waypoint, indent=2)}")
            
            # Handle different waypoint formats
            if 'position' in first_waypoint:
                mock_latitude = first_waypoint['position']['latitude']
                mock_longitude = first_waypoint['position']['longitude']
            elif 'latitude' in first_waypoint and 'longitude' in first_waypoint:
                mock_latitude = first_waypoint['latitude']
                mock_longitude = first_waypoint['longitude']
            else:
                print("Error: Waypoint format not recognized")
                print(f"Available keys: {list(first_waypoint.keys())}")
                return
            
            current_waypoint_index = 0
            print(f"Starting at position: {mock_latitude}, {mock_longitude}")
    
    is_mission_active = True
    emit('mission_status', {'status': 'started'})
    print("Mission started, telemetry will begin emitting")

@socketio.on('pause_mission')
def handle_pause_mission():
    global is_mission_active
    is_mission_active = False
    emit('mission_status', {'status': 'paused'})

@socketio.on('resume_mission')
def handle_resume_mission():
    global is_mission_active
    is_mission_active = True
    emit('mission_status', {'status': 'resumed'})

@socketio.on('stop_mission')
def handle_stop_mission():
    global is_mission_active, mock_mission_progress, current_waypoint_index
    is_mission_active = False
    mock_mission_progress = 0
    current_waypoint_index = 0
    emit('mission_status', {'status': 'stopped'})

@socketio.on('emergency_return')
def handle_emergency_return():
    global is_mission_active, mock_mission_progress, current_waypoint_index
    is_mission_active = False
    mock_mission_progress = 0
    current_waypoint_index = 0
    emit('mission_status', {'status': 'emergency_return'})

def generate_telemetry():
    global mock_latitude, mock_longitude, mock_altitude, mock_speed, mock_heading
    global mock_battery, mock_spray, mock_mission_progress, is_mission_active, current_waypoint_index
    
    while True:
        if is_mission_active and mission_waypoints:
            # Calculate progress based on waypoints
            total_waypoints = len(mission_waypoints)
            if total_waypoints > 0:
                # Move towards current waypoint
                current_waypoint = mission_waypoints[current_waypoint_index]
                
                # Get target coordinates
                if 'position' in current_waypoint:
                    target_lat = current_waypoint['position']['latitude']
                    target_lng = current_waypoint['position']['longitude']
                elif 'latitude' in current_waypoint and 'longitude' in current_waypoint:
                    target_lat = current_waypoint['latitude']
                    target_lng = current_waypoint['longitude']
                else:
                    print(f"Error: Waypoint format not recognized: {current_waypoint}")
                    continue
                
                # Calculate distance to target
                lat_diff = target_lat - mock_latitude
                lng_diff = target_lng - mock_longitude
                distance = (lat_diff**2 + lng_diff**2)**0.5
                
                # Move towards target (1% of remaining distance)
                if distance > 0.00001:  # If not close enough to waypoint
                    mock_latitude += lat_diff * 0.01
                    mock_longitude += lng_diff * 0.01
                    
                    # Calculate heading based on movement direction
                    mock_heading = (math.atan2(lng_diff, lat_diff) * 180 / math.pi) % 360
                else:
                    # Reached current waypoint, move to next
                    current_waypoint_index = min(current_waypoint_index + 1, total_waypoints - 1)
                
                # Update mission progress
                mock_mission_progress = int((current_waypoint_index / total_waypoints) * 100)
                
                # If reached last waypoint, complete mission
                if current_waypoint_index >= total_waypoints - 1 and distance <= 0.00001:
                    is_mission_active = False
                    mock_mission_progress = 100
                    print("Mission completed!")
        
        # Update other telemetry values
        mock_altitude = 30 + random.uniform(-2, 2)
        mock_speed = 5 + random.uniform(-1, 1)
        mock_battery = max(0, mock_battery - random.uniform(0, 0.1))
        mock_spray = max(0, mock_spray - random.uniform(0, 0.05))
        
        # Create telemetry data
        telemetry = {
            'latitude': mock_latitude,
            'longitude': mock_longitude,
            'altitude': mock_altitude,
            'speed': mock_speed,
            'heading': mock_heading,
            'batteryPercentage': int(mock_battery),
            'sprayLevel': int(mock_spray),
            'missionProgress': int(mock_mission_progress),
            'timestamp': datetime.now().isoformat()
        }
        
        # Only emit telemetry if a mission is active
        if is_mission_active:
            # Print telemetry data for debugging
            print(f"telem: {telemetry}")
            
            # Emit telemetry data
            socketio.emit('telemetry', telemetry)
        
        # Wait for 1 second
        time.sleep(1)

if __name__ == '__main__':
    telemetry_thread = threading.Thread(target=generate_telemetry)
    telemetry_thread.daemon = True
    telemetry_thread.start()
    
    # Run the server on all network interfaces (0.0.0.0)
    # This allows connections from other devices on the network
    port = int(os.environ.get('PORT', 5000))
    print(f"Starting Agron GCS Server on port {port}")
    socketio.run(app, host='0.0.0.0', port=port, debug=True) 