FROM python:3.10-slim

WORKDIR /app

# Install PDM
RUN pip install --no-cache-dir pdm

# Copy dependency files
COPY pyproject.toml pdm.lock ./

# Install server dependencies only (PyQt6/PyInstaller are desktop-only dev deps)
RUN pdm install --prod -G server

# Copy application code
COPY . .

# Create non-root user
RUN useradd -m lnreader && \
    chown -R lnreader:lnreader /app

USER lnreader

# Set environment variables
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1