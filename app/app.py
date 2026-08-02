"""
SRE HandsOn Evaluation - Notes API
====================================
A minimal Flask microservice with:
  - / (root)         : simple HTML frontend
  - /health          : liveness/readiness endpoint for Kubernetes probes
  - /metrics         : Prometheus metrics endpoint (auto-generated)
  - /api/notes       : GET all notes / POST a new note (uses Postgres)
  - /api/stress      : CPU-intensive endpoint (for failure testing)
"""

import os
import socket
import time
import logging
from datetime import datetime

from flask import Flask, request, jsonify, render_template
from prometheus_flask_exporter import PrometheusMetrics
from prometheus_client import Counter
import psycopg2
from psycopg2.extras import RealDictCursor


# ---------------------------------------------------------------------------
# Logging setup — structured logs stream to stdout, which Promtail ships to Loki
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
logger = logging.getLogger("notes-api")


# ---------------------------------------------------------------------------
# Flask app + Prometheus metrics
# ---------------------------------------------------------------------------
app = Flask(__name__)

# Auto-instruments every route with request count, latency histograms, etc.
# Exposes /metrics endpoint automatically.
metrics = PrometheusMetrics(app)
metrics.info("notes_api_info", "Notes API build info", version="1.0.0")

# Custom metric: total notes created (proper Prometheus Counter)
notes_created_total = Counter(
    "notes_created_total",
    "Total number of notes created",
)


# ---------------------------------------------------------------------------
# Database configuration — read from environment variables
# (NEVER hardcode secrets — this is why we use ConfigMap + Secret in k8s)
# ---------------------------------------------------------------------------
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "notesdb")
DB_USER = os.environ.get("DB_USER", "notes")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "changeme")

APP_START_TIME = time.time()


def get_db_connection():
    """Open a fresh connection to Postgres. Called per request (simple pattern)."""
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=5,  # Fail fast — 5 seconds instead of default 30
    )


def init_db():
    """Create the notes table if it doesn't exist. Retries on startup."""
    max_retries = 10
    for attempt in range(1, max_retries + 1):
        try:
            conn = get_db_connection()
            cur = conn.cursor()
            cur.execute("""
                CREATE TABLE IF NOT EXISTS notes (
                    id SERIAL PRIMARY KEY,
                    content TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            conn.commit()
            cur.close()
            conn.close()
            logger.info("Database initialized successfully")
            return
        except Exception as e:
            logger.warning(f"DB init attempt {attempt}/{max_retries} failed: {e}")
            time.sleep(3)
    logger.error("Failed to initialize database after retries — continuing anyway")


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    """The frontend — a simple HTML page with a form."""
    return render_template("index.html", hostname=socket.gethostname())


@app.route("/health")
def health():
    """
    Liveness/readiness probe endpoint.
    - Kubernetes hits this every few seconds.
    - Returns 200 = pod is alive. Returns non-200 = pod gets restarted.
    """
    return jsonify({
        "status": "healthy",
        "hostname": socket.gethostname(),
        "uptime_seconds": round(time.time() - APP_START_TIME, 2),
    }), 200


@app.route("/api/notes", methods=["GET"])
def get_notes():
    """Fetch all notes from Postgres, newest first."""
    try:
        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("SELECT id, content, created_at FROM notes ORDER BY id DESC LIMIT 50")
        notes = cur.fetchall()
        cur.close()
        conn.close()
        # Convert datetime to string for JSON serialization
        for n in notes:
            n["created_at"] = n["created_at"].isoformat()
        logger.info(f"Fetched {len(notes)} notes")
        return jsonify({"notes": notes}), 200
    except Exception as e:
        logger.error(f"Failed to fetch notes: {e}")
        return jsonify({"error": "database unavailable"}), 503


@app.route("/api/notes", methods=["POST"])
def create_note():
    """Add a new note to Postgres."""
    data = request.get_json(silent=True) or {}
    content = (data.get("content") or "").strip()
    if not content:
        return jsonify({"error": "content is required"}), 400

    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO notes (content) VALUES (%s) RETURNING id",
            (content,),
        )
        new_id = cur.fetchone()[0]
        conn.commit()
        cur.close()
        conn.close()
        notes_created_total.inc()  # bump the Prometheus counter
        logger.info(f"Created note id={new_id}")
        return jsonify({"id": new_id, "content": content}), 201
    except Exception as e:
        logger.error(f"Failed to create note: {e}")
        return jsonify({"error": "database unavailable"}), 503


@app.route("/api/stress", methods=["POST"])
def stress():
    """
    CPU-intensive endpoint — burns CPU for a given duration (default 5s).
    Used to trigger the 'High CPU' failure scenario during demo.
    """
    duration = int(request.args.get("duration", 5))
    duration = min(duration, 30)  # Cap at 30s to avoid abuse
    logger.warning(f"Stress test starting for {duration}s")

    end_time = time.time() + duration
    x = 0
    while time.time() < end_time:
        x += 1  # busy loop

    logger.warning(f"Stress test completed after {duration}s (iterations: {x})")
    return jsonify({"stressed_for_seconds": duration, "iterations": x}), 200


# ---------------------------------------------------------------------------
# Initialize DB at import time so it runs under gunicorn too
# (gunicorn imports the module; it does NOT execute the __main__ block)
# ---------------------------------------------------------------------------
init_db()

# ---------------------------------------------------------------------------
# Entrypoint (only used when running directly, e.g. python app.py)
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)