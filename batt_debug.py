#!/usr/bin/env python3
import os
import time
from pymavlink import mavutil

# Configure via env vars if needed:
#   MAVLINK_PORT=/dev/ttyAMA0 MAVLINK_BAUD=57600 ./batt_debug.py
PORT = os.environ.get("MAVLINK_PORT", "/dev/ttyACM0")
BAUD = int(os.environ.get("MAVLINK_BAUD", "115200"))


def request_battery_streams(m: "mavutil.mavfile") -> None:
    try:
        for msg_id, hz in [
            (mavutil.mavlink.MAVLINK_MSG_ID_SYS_STATUS, 1),
            (mavutil.mavlink.MAVLINK_MSG_ID_BATTERY_STATUS, 1),
        ]:
            m.mav.command_long_send(
                m.target_system,
                m.target_component or mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1,
                mavutil.mavlink.MAV_CMD_SET_MESSAGE_INTERVAL,
                0,
                msg_id,
                int(1_000_000 / hz),
                0, 0, 0, 0, 0,
            )
    except Exception:
        pass


def main() -> None:
    print(f"[BAT] Connecting to {PORT} @ {BAUD}")
    m = mavutil.mavlink_connection(PORT, baud=BAUD, force_mavlink2=True)
    m.wait_heartbeat(timeout=10)
    print(f"[BAT] Heartbeat from sys {m.target_system} comp {m.target_component}")

    request_battery_streams(m)

    while True:
        msg = m.recv_match(type=["SYS_STATUS", "BATTERY_STATUS"], blocking=True, timeout=2)
        now = time.strftime("%H:%M:%S")
        if not msg:
            print(f"[{now}] (timeout waiting battery msg)")
            continue

        t = msg.get_type()
        if t == "SYS_STATUS":
            vb_mv = getattr(msg, "voltage_battery", None)  # millivolts
            ib_cA = getattr(msg, "current_battery", None)  # 10 * A
            rem = getattr(msg, "battery_remaining", None)  # percent
            vb = f"{vb_mv/1000.0:.2f}V" if isinstance(vb_mv, int) and vb_mv > 0 else "--"
            ib = f"{ib_cA/10.0:.1f}A" if isinstance(ib_cA, int) and ib_cA != -1 else "--"
            pr = f"{int(rem)}%" if isinstance(rem, int) and rem is not None and rem >= 0 else "--"
            print(f"[{now}] SYS_STATUS  voltage={vb}  current={ib}  remaining={pr}")

        elif t == "BATTERY_STATUS":
            try:
                vols = [v for v in (msg.voltages or []) if v and v > 0]  # mV per cell
                vb = f"{(sum(vols)/len(vols))/1000.0:.2f}V" if vols else "--"
            except Exception:
                vb = "--"
            rem = getattr(msg, "battery_remaining", None)
            pr = f"{int(rem)}%" if isinstance(rem, int) and rem is not None and rem >= 0 else "--"
            print(f"[{now}] BATTERY_STATUS  avg_voltage={vb}  remaining={pr}")


if __name__ == "__main__":
    main()



