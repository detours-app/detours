#!/bin/bash
set -euo pipefail

# Screenshot setup script for Detours
# Creates sample folders/files for taking README screenshots
# Usage: ./resources/scripts/screenshot-setup.sh

BASE="/tmp/detours-screenshot"

echo "==> Creating screenshot folders..."

# Clean up any existing setup
rm -rf "$BASE"
mkdir -p "$BASE"

# ============================================
# LEFT PANE: acme-corp (business/finance)
# ============================================
CORP="$BASE/acme-corp"
mkdir -p "$CORP"

# Folders with content
mkdir -p "$CORP/contracts"
dd if=/dev/urandom bs=1024 count=300 2>/dev/null | base64 > "$CORP/contracts/ClientA-2025.pdf"
dd if=/dev/urandom bs=1024 count=400 2>/dev/null | base64 > "$CORP/contracts/ClientB-2026.pdf"
dd if=/dev/urandom bs=1024 count=250 2>/dev/null | base64 > "$CORP/contracts/Vendor-NDA.pdf"

mkdir -p "$CORP/invoices"
for i in {1..12}; do
    dd if=/dev/urandom bs=1024 count=$((10 + RANDOM % 20)) 2>/dev/null | base64 > "$CORP/invoices/INV-2025-$(printf '%03d' $i).pdf"
done

mkdir -p "$CORP/reports"
dd if=/dev/urandom bs=1024 count=1500 2>/dev/null | base64 > "$CORP/reports/Q4-2025-Financial.pdf"
dd if=/dev/urandom bs=1024 count=2000 2>/dev/null | base64 > "$CORP/reports/Annual-Review-2025.pdf"
dd if=/dev/urandom bs=1024 count=800 2>/dev/null | base64 > "$CORP/reports/Market-Analysis.pdf"

mkdir -p "$CORP/team"
dd if=/dev/urandom bs=1024 count=50 2>/dev/null | base64 > "$CORP/team/org-chart.pdf"
dd if=/dev/urandom bs=1024 count=150 2>/dev/null | base64 > "$CORP/team/Employee-Directory.xlsx"
dd if=/dev/urandom bs=1024 count=30 2>/dev/null | base64 > "$CORP/team/contact-list.csv"

# Files in root
dd if=/dev/urandom bs=1024 count=95 2>/dev/null | base64 > "$CORP/Budget-2026.xlsx"
dd if=/dev/urandom bs=1024 count=1600 2>/dev/null | base64 > "$CORP/Company-Handbook.pdf"

cat > "$CORP/Meeting-Notes.md" << 'NOTES'
# Meeting Notes - January 2026

## Q1 Planning Session

### Attendees
- Sarah Chen (CEO)
- Marcus Webb (CFO)
- Elena Rodriguez (CTO)
- James Park (VP Sales)

### Agenda
1. Q4 2025 Review
2. Budget allocation for Q1
3. Hiring roadmap
4. Product launch timeline

### Key Decisions
- Approved $2.4M budget for engineering expansion
- Green-lit Project Horizon for March release
- New office space lease signed through 2028

### Action Items
- [ ] Marcus to finalize Q1 budget spreadsheet
- [ ] Elena to draft technical hiring plan
- [ ] James to prepare sales forecasts
- [ ] Sarah to communicate changes to board

### Next Meeting
February 3rd, 2026 at 10:00 AM
NOTES

# ============================================
# RIGHT PANE: taskflow (dev project with git)
# ============================================
DEV="$BASE/taskflow"
mkdir -p "$DEV"
cd "$DEV"

# Initialize git repo
git init -q

# Create project structure
mkdir -p api docs tests web

# API folder
cat > api/main.py << 'PY'
"""TaskFlow API - Main entry point."""
from fastapi import FastAPI
from .routes import tasks, users, projects
from .middleware import auth, logging

app = FastAPI(title="TaskFlow API", version="2.1.0")

app.include_router(tasks.router, prefix="/tasks")
app.include_router(users.router, prefix="/users")
app.include_router(projects.router, prefix="/projects")

@app.get("/health")
async def health_check():
    return {"status": "healthy", "version": "2.1.0"}
PY

cat > api/models.py << 'PY'
"""Database models for TaskFlow."""
from sqlalchemy import Column, Integer, String, DateTime, ForeignKey
from sqlalchemy.orm import relationship
from .database import Base

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    email = Column(String, unique=True, index=True)
    name = Column(String)
    tasks = relationship("Task", back_populates="owner")

class Task(Base):
    __tablename__ = "tasks"
    id = Column(Integer, primary_key=True)
    title = Column(String, index=True)
    description = Column(String)
    status = Column(String, default="pending")
    owner_id = Column(Integer, ForeignKey("users.id"))
    owner = relationship("User", back_populates="tasks")
PY

cat > api/routes.py << 'PY'
"""API route handlers."""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from . import models, schemas
from .database import get_db

router = APIRouter()

@router.get("/")
async def list_tasks(db: Session = Depends(get_db)):
    return db.query(models.Task).all()

@router.post("/")
async def create_task(task: schemas.TaskCreate, db: Session = Depends(get_db)):
    db_task = models.Task(**task.dict())
    db.add(db_task)
    db.commit()
    return db_task
PY

# Docs folder
cat > docs/architecture.md << 'MD'
# TaskFlow Architecture

## Overview
TaskFlow is a modern task management platform built with FastAPI and React.

## Components
- **API Server**: FastAPI with SQLAlchemy ORM
- **Web Client**: React with TypeScript
- **Database**: PostgreSQL 15
- **Cache**: Redis for session management
MD

cat > docs/api-reference.md << 'MD'
# API Reference

## Authentication
All endpoints require Bearer token authentication.

## Endpoints

### Tasks
- `GET /tasks` - List all tasks
- `POST /tasks` - Create a task
- `GET /tasks/{id}` - Get task details
- `PUT /tasks/{id}` - Update a task
- `DELETE /tasks/{id}` - Delete a task
MD

# Tests folder
cat > tests/test_api.py << 'PY'
"""API integration tests."""
import pytest
from fastapi.testclient import TestClient
from api.main import app

client = TestClient(app)

def test_health_check():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "healthy"

def test_create_task():
    response = client.post("/tasks", json={"title": "Test task"})
    assert response.status_code == 201
PY

cat > tests/test_models.py << 'PY'
"""Model unit tests."""
import pytest
from api.models import User, Task

def test_user_creation():
    user = User(email="test@example.com", name="Test User")
    assert user.email == "test@example.com"

def test_task_default_status():
    task = Task(title="New task")
    assert task.status == "pending"
PY

# Web folder
cat > web/App.tsx << 'TSX'
import React from 'react';
import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { Dashboard } from './pages/Dashboard';
import { TaskList } from './pages/TaskList';
import { Settings } from './pages/Settings';

export const App: React.FC = () => {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Dashboard />} />
        <Route path="/tasks" element={<TaskList />} />
        <Route path="/settings" element={<Settings />} />
      </Routes>
    </BrowserRouter>
  );
};
TSX

cat > web/components.tsx << 'TSX'
import React from 'react';

interface TaskCardProps {
  title: string;
  status: 'pending' | 'active' | 'done';
  assignee?: string;
}

export const TaskCard: React.FC<TaskCardProps> = ({ title, status, assignee }) => {
  return (
    <div className={`task-card task-${status}`}>
      <h3>{title}</h3>
      {assignee && <span className="assignee">{assignee}</span>}
      <span className={`badge badge-${status}`}>{status}</span>
    </div>
  );
};
TSX

dd if=/dev/urandom bs=1024 count=25 2>/dev/null | base64 > web/styles.css

# Root files
cat > pyproject.toml << 'TOML'
[project]
name = "taskflow"
version = "2.1.0"
description = "Modern task management platform"
requires-python = ">=3.11"

[project.dependencies]
fastapi = ">=0.109.0"
sqlalchemy = ">=2.0.0"
uvicorn = ">=0.27.0"
pydantic = ">=2.5.0"
TOML

cat > README.md << 'MD'
# TaskFlow

A modern task management platform for teams.

## Quick Start

```bash
pip install -e .
uvicorn api.main:app --reload
```

## Features
- Real-time collaboration
- Project boards with drag-and-drop
- Time tracking and reports
- Integrations with Slack, GitHub, Jira

## License
MIT
MD

# Initial commit
git add -A
git commit -q -m "Initial commit"

# Create some git status variety
echo "# Adding new feature" >> api/models.py
git add api/models.py  # staged

echo "// TODO: Add dark mode" >> web/App.tsx  # modified (unstaged)

cat > api/cache.py << 'PY'
"""Redis cache utilities."""
import redis

client = redis.Redis(host='localhost', port=6379, db=0)

def get_cached(key: str):
    return client.get(key)

def set_cached(key: str, value: str, ttl: int = 300):
    client.setex(key, ttl, value)
PY
# cache.py is untracked

echo ""
echo "==> Screenshot folders created at: $BASE"
echo ""
echo "Left pane:  $CORP"
echo "Right pane: $DEV"
echo ""
echo "Git status in taskflow:"
cd "$DEV" && git status --short
echo ""
echo "==> Open Detours and navigate to these folders"
echo "==> Make sure sidebar is visible (Cmd-0)"
echo "==> Select Budget-2026.xlsx in left pane for highlight"
