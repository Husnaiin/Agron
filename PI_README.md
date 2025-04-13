# Agron GCS Raspberry Pi Server

This is the server component for the Agron GCS application that runs on a Raspberry Pi. It provides mock telemetry data and handles WebSocket connections for real-time communication with the Flutter app.

## Setup Instructions

### 1. Install Required Packages

```bash
sudo apt-get update
sudo apt-get install -y python3-pip python3-venv
```

### 2. Create a Virtual Environment

```bash
python3 -m venv venv
source venv/bin/activate
```

### 3. Install Dependencies

```bash
pip install -r requirements.txt
```

### 4. Configure Network

For the Flutter app to connect to the Raspberry Pi, you need to know the Pi's IP address. You can find it using:

```bash
hostname -I
```

The first IP address shown is the one you'll use to connect from the Flutter app.

### 5. Run the Server

```bash
python server.py
```

The server will start on port 5000 by default. You can change this by setting the PORT environment variable:

```bash
PORT=8080 python server.py
```

## Connecting from the Flutter App

1. Open the Agron GCS app on your mobile device
2. Make sure your mobile device is connected to the same network as the Raspberry Pi
3. Click the WiFi icon in the app bar
4. Enter the Raspberry Pi's IP address (e.g., 192.168.1.100)
5. Click "Connect"

## Testing the Connection

You can test if the server is running by accessing the status endpoint in a web browser:

```
http://<raspberry-pi-ip>:5000/status
```

You should see a JSON response like:

```json
{
  "status": "ok",
  "message": "Agron GCS Server is running"
}
```

## Troubleshooting

### Connection Issues

1. Make sure both the Raspberry Pi and your mobile device are on the same network
2. Check if the Raspberry Pi's firewall is blocking port 5000
3. Verify the IP address is correct

### Server Not Starting

1. Check if port 5000 is already in use:
   ```bash
   sudo lsof -i :5000
   ```
2. If it is, kill the process or use a different port

## Future Integration with Pixhawk

When you're ready to integrate with a real Pixhawk flight controller:

1. Install the `pymavlink` package:
   ```bash
   pip install pymavlink
   ```

2. Modify the `generate_mock_telemetry` function in `server.py` to read real telemetry data from the Pixhawk instead of generating mock values.

3. Connect the Pixhawk to the Raspberry Pi via USB or UART and update the code to communicate with it. 