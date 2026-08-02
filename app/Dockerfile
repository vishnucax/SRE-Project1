# ---------------------------------------------------------------------------
# Notes API — Dockerfile
# Uses a slim Python base to keep the image small and reduce attack surface.
# ---------------------------------------------------------------------------
FROM python:3.12-slim

# Prevent Python from writing .pyc files and buffering stdout
# (unbuffered stdout = logs appear immediately, important for Loki)
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Create a non-root user (security best practice — never run as root)
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

# Install dependencies first (Docker layer caching — deps rarely change,
# so this layer is reused across builds, making builds faster)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the application code
COPY app.py .
COPY templates/ templates/

# Drop privileges — run as the non-root user
USER appuser

# Document which port the app listens on
EXPOSE 8080

# Health check (Docker-level; k8s probes are separate but this is good practice)
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

# Run with gunicorn (production WSGI server), not Flask's dev server.
# - 2 workers, 4 threads each = decent concurrency for a small app
# - bind to all interfaces on 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", "--access-logfile", "-", "app:app"]