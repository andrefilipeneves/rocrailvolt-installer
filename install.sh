#!/bin/bash
set -e

echo "=============================================="
echo "   RocrailVolt Installer (YOLO ON) - Pi 5"
echo "   Author: andrefilipeneves"
echo "=============================================="

USER_HOME="/home/andrefilipeneves"
PROJECT_DIR="$USER_HOME/RocrailVolt"
PLAN_PATH="$USER_HOME/Documents/rocrail/demo/plan.xml"
CS3_IP="192.168.59.36"

echo "[1/20] Updating system..."
sudo apt update -y
sudo apt upgrade -y

echo "[2/20] Installing system dependencies (Debian 12/13 compatible)..."
sudo apt install -y \
    python3 python3-venv python3-pip git curl unzip wget \
    libopenblas-dev liblapack-dev \
    libavcodec-dev libavformat-dev libswscale-dev \
    libgtk-3-dev libqt5gui5 libqt5widgets5 libqt5core5a \
    python3-opencv

echo "[3/20] Creating project directory..."
rm -rf "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/apps"
mkdir -p "$PROJECT_DIR/apps/home"
mkdir -p "$PROJECT_DIR/templates/home"
mkdir -p "$PROJECT_DIR/templates/layouts"
mkdir -p "$PROJECT_DIR/static/css"
mkdir -p "$PROJECT_DIR/static/js"
mkdir -p "$PROJECT_DIR/static/img"
mkdir -p "$PROJECT_DIR/data"

echo "[4/20] Creating virtual environment..."
python3 -m venv "$PROJECT_DIR/venv"

echo "[5/20] Activating virtual environment..."
source "$PROJECT_DIR/venv/bin/activate"

echo "[6/20] Creating requirements.txt..."
cat > "$PROJECT_DIR/requirements.txt" << 'EOF'
flask
flask-cors
requests
ultralytics
EOF

echo "[7/20] Installing pip requirements..."
pip install --upgrade pip
pip install -r "$PROJECT_DIR/requirements.txt"

echo "[8/20] Creating run.py..."
cat > "$PROJECT_DIR/run.py" << 'EOF'
from apps import create_app

app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
EOF

echo "[9/20] Creating apps/__init__.py..."
cat > "$PROJECT_DIR/apps/__init__.py" << 'EOF'
from flask import Flask

def create_app():
    app = Flask(__name__)

    from apps.home import blueprint as home_blueprint
    app.register_blueprint(home_blueprint)

    return app
EOF

echo "[10/20] Creating apps/home/__init__.py..."
cat > "$PROJECT_DIR/apps/home/__init__.py" << 'EOF'
from flask import Blueprint

blueprint = Blueprint(
    'home_blueprint',
    __name__,
    url_prefix='',
    template_folder='../../templates',
    static_folder='../../static'
)

from apps.home import routes
EOF

echo "[11/20] Creating apps/home/routes.py..."
cat > "$PROJECT_DIR/apps/home/routes.py" << 'EOF'
import time
from flask import render_template, Response, jsonify, request

from apps.home import blueprint
from apps.yolo_core import yolo_camera
from apps.rocrail_plan import parse_plan
from apps import roi_store

@blueprint.route("/")
def index():
    return render_template("home/ai_dashboard.html")

@blueprint.route("/ai-dashboard")
def ai_dashboard():
    return render_template("home/ai_dashboard.html")

@blueprint.route("/yolo-stream")
def yolo_stream():
    return Response(
        yolo_camera(),
        mimetype="multipart/x-mixed-replace; boundary=frame"
    )

@blueprint.route("/api/roi", methods=["GET"])
def api_roi_get():
    return jsonify({"rois": roi_store.load_rois()})

@blueprint.route("/api/roi", methods=["POST"])
def api_roi_save():
    data = request.get_json() or {}
    rois = data.get("rois", [])
    roi_store.save_rois(rois)
    return jsonify({"ok": True})
EOF

echo "[12/20] Creating apps/yolo_core.py..."
cat > "$PROJECT_DIR/apps/yolo_core.py" << 'EOF'
import cv2
from ultralytics import YOLO

IP_CAM = "rtsp://comboios:comboios2025@192.168.59.38:554/stream2"
model = YOLO("yolo11n.pt")

def yolo_camera():
    cap = cv2.VideoCapture(IP_CAM)
    if not cap.isOpened():
        print("Camera not opened")
        return

    while True:
        ret, frame = cap.read()
        if not ret:
            continue

        results = model.predict(frame, verbose=False)[0]

        for box in results.boxes:
            x1, y1, x2, y2 = map(int, box.xyxy[0].tolist())
            cv2.rectangle(frame, (x1, y1), (x2, y2), (0,255,0), 2)

        _, buffer = cv2.imencode('.jpg', frame)
        yield (b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + buffer.tobytes() + b"\r\n")
EOF

echo "[13/20] Creating apps/roi_store.py..."
cat > "$PROJECT_DIR/apps/roi_store.py" << 'EOF'
import json
import os

DATA_FILE = "data/roi_layout.json"

def load_rois():
    if not os.path.exists(DATA_FILE):
        return []
    with open(DATA_FILE, "r") as f:
        return json.load(f)

def save_rois(rois):
    with open(DATA_FILE, "w") as f:
        json.dump(rois, f)
EOF

echo "[14/20] Creating apps/rocrail_plan.py..."
cat > "$PROJECT_DIR/apps/rocrail_plan.py" << 'EOF'
import xml.etree.ElementTree as ET

PLAN = "/home/andrefilipeneves/Documents/rocrail/demo/plan.xml"

def parse_plan():
    tree = ET.parse(PLAN)
    root = tree.getroot()

    blocks = []
    locos = []

    for b in root.findall(".//block"):
        blocks.append({
            "id": b.get("id"),
            "state": b.get("state", "free")
        })

    for l in root.findall(".//loc"):
        locos.append({
            "id": l.get("id"),
            "addr": l.get("addr")
        })

    return {"blocks": blocks, "locos": locos}
EOF

echo "[15/20] Creating template..."
cat > "$PROJECT_DIR/templates/home/ai_dashboard.html" << 'EOF'
<h1 style="color:white;">AI Dashboard</h1>
<img src="/yolo-stream" style="width:100%; border-radius:10px;">
EOF

echo "[16/20] Creating start.sh..."
cat > "$PROJECT_DIR/start.sh" << 'EOF'
#!/bin/bash
source venv/bin/activate
python3 run.py
EOF

chmod +x "$PROJECT_DIR/start.sh"

echo "[17/20] Creating stop.sh..."
cat > "$PROJECT_DIR/stop.sh" << 'EOF'
#!/bin/bash
pkill -f run.py
pkill -f python
EOF

chmod +x "$PROJECT_DIR/stop.sh"

echo "[18/20] Downloading Rocrail..."
cd /tmp
wget https://wiki.rocrail.net/rocrail-snapshot/rocrail-14617-Linux-x86_64.tgz -O rocrail.tgz
sudo mkdir -p /opt/rocrail
sudo tar -xzf rocrail.tgz -C /opt/rocrail --strip-components=1

echo "[19/20] Creating Rocrail service..."
sudo tee /etc/systemd/system/rocrail.service > /dev/null << EOF
[Unit]
Description=Rocrail Server
After=network.target

[Service]
ExecStart=/opt/rocrail/rocrail
WorkingDirectory=/opt/rocrail
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable rocrail
sudo systemctl start rocrail

echo "[20/20] Installation complete!"
echo "=============================================="
echo "   Run the application:"
echo "   cd ~/RocrailVolt && ./start.sh"
echo "=============================================="
