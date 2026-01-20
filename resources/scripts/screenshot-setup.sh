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

# Set varied dates for acme-corp files
touch -t 202503151000 "$CORP/contracts/ClientA-2025.pdf"
touch -t 202506201430 "$CORP/contracts/ClientB-2026.pdf"
touch -t 202504101100 "$CORP/contracts/Vendor-NDA.pdf"

touch -t 202501150900 "$CORP/invoices/INV-2025-001.pdf"
touch -t 202502151000 "$CORP/invoices/INV-2025-002.pdf"
touch -t 202503151100 "$CORP/invoices/INV-2025-003.pdf"
touch -t 202504151200 "$CORP/invoices/INV-2025-004.pdf"
touch -t 202505151300 "$CORP/invoices/INV-2025-005.pdf"
touch -t 202506151400 "$CORP/invoices/INV-2025-006.pdf"
touch -t 202507151500 "$CORP/invoices/INV-2025-007.pdf"
touch -t 202508151600 "$CORP/invoices/INV-2025-008.pdf"
touch -t 202509151700 "$CORP/invoices/INV-2025-009.pdf"
touch -t 202510151800 "$CORP/invoices/INV-2025-010.pdf"
touch -t 202511150900 "$CORP/invoices/INV-2025-011.pdf"
touch -t 202512151000 "$CORP/invoices/INV-2025-012.pdf"

touch -t 202512181400 "$CORP/reports/Q4-2025-Financial.pdf"
touch -t 202601051030 "$CORP/reports/Annual-Review-2025.pdf"
touch -t 202511201600 "$CORP/reports/Market-Analysis.pdf"

touch -t 202508101200 "$CORP/team/org-chart.pdf"
touch -t 202510051430 "$CORP/team/Employee-Directory.xlsx"
touch -t 202512011100 "$CORP/team/contact-list.csv"

touch -t 202512101500 "$CORP/Budget-2026.xlsx"
touch -t 202509151100 "$CORP/Company-Handbook.pdf"
touch -t 202601151430 "$CORP/Meeting-Notes.md"

# ============================================
# RIGHT PANE: taskflow (dev project with git)
# Many files with varied git statuses
# ============================================
DEV="$BASE/taskflow"
mkdir -p "$DEV"
cd "$DEV"

# Initialize git repo
git init -q

# Create project structure
mkdir -p api api/middleware api/schemas docs tests web web/components web/hooks web/pages config scripts migrations

# ---- API folder ----
cat > api/__init__.py << 'PY'
"""TaskFlow API package."""
__version__ = "2.1.0"
PY

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

cat > api/database.py << 'PY'
"""Database connection and session management."""
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base

DATABASE_URL = "postgresql://localhost/taskflow"
engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(bind=engine)
Base = declarative_base()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
PY

cat > api/config.py << 'PY'
"""Application configuration."""
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    database_url: str = "postgresql://localhost/taskflow"
    redis_url: str = "redis://localhost:6379/0"
    secret_key: str = "change-me-in-production"
    debug: bool = False

    class Config:
        env_file = ".env"

settings = Settings()
PY

cat > api/middleware/__init__.py << 'PY'
"""Middleware package."""
from .auth import AuthMiddleware
from .logging import LoggingMiddleware
PY

cat > api/middleware/auth.py << 'PY'
"""Authentication middleware."""
from fastapi import Request, HTTPException
from starlette.middleware.base import BaseHTTPMiddleware

class AuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if request.url.path.startswith("/api/"):
            token = request.headers.get("Authorization")
            if not token:
                raise HTTPException(status_code=401)
        return await call_next(request)
PY

cat > api/middleware/logging.py << 'PY'
"""Request logging middleware."""
import time
import logging
from starlette.middleware.base import BaseHTTPMiddleware

logger = logging.getLogger(__name__)

class LoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        start = time.time()
        response = await call_next(request)
        duration = time.time() - start
        logger.info(f"{request.method} {request.url.path} - {duration:.3f}s")
        return response
PY

cat > api/middleware/cors.py << 'PY'
"""CORS middleware configuration."""
from fastapi.middleware.cors import CORSMiddleware

ALLOWED_ORIGINS = [
    "http://localhost:3000",
    "https://taskflow.app",
]

def setup_cors(app):
    app.add_middleware(
        CORSMiddleware,
        allow_origins=ALLOWED_ORIGINS,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
PY

cat > api/schemas/__init__.py << 'PY'
"""Pydantic schemas package."""
from .task import TaskCreate, TaskUpdate, TaskResponse
from .user import UserCreate, UserResponse
PY

cat > api/schemas/task.py << 'PY'
"""Task schemas."""
from pydantic import BaseModel
from datetime import datetime
from typing import Optional

class TaskBase(BaseModel):
    title: str
    description: Optional[str] = None

class TaskCreate(TaskBase):
    pass

class TaskUpdate(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None
    status: Optional[str] = None

class TaskResponse(TaskBase):
    id: int
    status: str
    created_at: datetime

    class Config:
        from_attributes = True
PY

cat > api/schemas/user.py << 'PY'
"""User schemas."""
from pydantic import BaseModel, EmailStr

class UserCreate(BaseModel):
    email: EmailStr
    name: str
    password: str

class UserResponse(BaseModel):
    id: int
    email: str
    name: str

    class Config:
        from_attributes = True
PY

cat > api/utils.py << 'PY'
"""Utility functions."""
import hashlib
import secrets

def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    hashed = hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), 100000)
    return f"{salt}:{hashed.hex()}"

def verify_password(password: str, hashed: str) -> bool:
    salt, hash_val = hashed.split(':')
    new_hash = hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), 100000)
    return new_hash.hex() == hash_val
PY

# ---- Docs folder ----
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

cat > docs/deployment.md << 'MD'
# Deployment Guide

## Docker

```bash
docker-compose up -d
```

## Environment Variables

- `DATABASE_URL` - PostgreSQL connection string
- `REDIS_URL` - Redis connection string
- `SECRET_KEY` - JWT signing key
MD

cat > docs/contributing.md << 'MD'
# Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `pytest`
5. Submit a pull request
MD

# ---- Tests folder ----
cat > tests/__init__.py << 'PY'
"""Test package."""
PY

cat > tests/conftest.py << 'PY'
"""Pytest fixtures."""
import pytest
from fastapi.testclient import TestClient
from api.main import app
from api.database import Base, engine

@pytest.fixture
def client():
    return TestClient(app)

@pytest.fixture(autouse=True)
def setup_db():
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)
PY

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

cat > tests/test_auth.py << 'PY'
"""Authentication tests."""
import pytest

def test_login_success(client):
    response = client.post("/auth/login", json={
        "email": "test@example.com",
        "password": "password123"
    })
    assert response.status_code == 200
    assert "access_token" in response.json()

def test_login_invalid_credentials(client):
    response = client.post("/auth/login", json={
        "email": "test@example.com",
        "password": "wrong"
    })
    assert response.status_code == 401
PY

cat > tests/test_tasks.py << 'PY'
"""Task endpoint tests."""
import pytest

def test_list_tasks_empty(client):
    response = client.get("/tasks")
    assert response.status_code == 200
    assert response.json() == []

def test_create_and_get_task(client):
    create_resp = client.post("/tasks", json={"title": "My Task"})
    task_id = create_resp.json()["id"]

    get_resp = client.get(f"/tasks/{task_id}")
    assert get_resp.json()["title"] == "My Task"
PY

cat > tests/test_users.py << 'PY'
"""User endpoint tests."""
import pytest

def test_create_user(client):
    response = client.post("/users", json={
        "email": "new@example.com",
        "name": "New User",
        "password": "secure123"
    })
    assert response.status_code == 201
PY

# ---- Web folder ----
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

cat > web/index.tsx << 'TSX'
import React from 'react';
import ReactDOM from 'react-dom/client';
import { App } from './App';
import './styles/global.css';

const root = ReactDOM.createRoot(document.getElementById('root')!);
root.render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
TSX

cat > web/api.ts << 'TSX'
const API_BASE = '/api/v1';

export async function fetchTasks() {
  const res = await fetch(`${API_BASE}/tasks`);
  return res.json();
}

export async function createTask(title: string) {
  const res = await fetch(`${API_BASE}/tasks`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title }),
  });
  return res.json();
}
TSX

cat > web/types.ts << 'TSX'
export interface Task {
  id: number;
  title: string;
  description?: string;
  status: 'pending' | 'active' | 'done';
  createdAt: string;
}

export interface User {
  id: number;
  email: string;
  name: string;
}
TSX

cat > web/components/TaskCard.tsx << 'TSX'
import React from 'react';
import { Task } from '../types';

interface Props {
  task: Task;
  onStatusChange: (status: string) => void;
}

export const TaskCard: React.FC<Props> = ({ task, onStatusChange }) => {
  return (
    <div className={`task-card task-${task.status}`}>
      <h3>{task.title}</h3>
      <span className={`badge badge-${task.status}`}>{task.status}</span>
    </div>
  );
};
TSX

cat > web/components/Header.tsx << 'TSX'
import React from 'react';
import { Link } from 'react-router-dom';

export const Header: React.FC = () => {
  return (
    <header className="header">
      <Link to="/" className="logo">TaskFlow</Link>
      <nav>
        <Link to="/tasks">Tasks</Link>
        <Link to="/settings">Settings</Link>
      </nav>
    </header>
  );
};
TSX

cat > web/components/Sidebar.tsx << 'TSX'
import React from 'react';

interface Props {
  projects: string[];
  activeProject: string;
  onSelect: (project: string) => void;
}

export const Sidebar: React.FC<Props> = ({ projects, activeProject, onSelect }) => {
  return (
    <aside className="sidebar">
      <h2>Projects</h2>
      <ul>
        {projects.map(p => (
          <li key={p} className={p === activeProject ? 'active' : ''}>
            <button onClick={() => onSelect(p)}>{p}</button>
          </li>
        ))}
      </ul>
    </aside>
  );
};
TSX

cat > web/components/Button.tsx << 'TSX'
import React from 'react';

interface Props extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'danger';
}

export const Button: React.FC<Props> = ({ variant = 'primary', children, ...props }) => {
  return (
    <button className={`btn btn-${variant}`} {...props}>
      {children}
    </button>
  );
};
TSX

cat > web/components/Modal.tsx << 'TSX'
import React from 'react';

interface Props {
  isOpen: boolean;
  onClose: () => void;
  title: string;
  children: React.ReactNode;
}

export const Modal: React.FC<Props> = ({ isOpen, onClose, title, children }) => {
  if (!isOpen) return null;

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={e => e.stopPropagation()}>
        <h2>{title}</h2>
        {children}
      </div>
    </div>
  );
};
TSX

cat > web/components/index.ts << 'TSX'
export { TaskCard } from './TaskCard';
export { Header } from './Header';
export { Sidebar } from './Sidebar';
export { Button } from './Button';
export { Modal } from './Modal';
TSX

cat > web/hooks/useTasks.ts << 'TSX'
import { useState, useEffect } from 'react';
import { Task } from '../types';
import { fetchTasks } from '../api';

export function useTasks() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetchTasks().then(data => {
      setTasks(data);
      setLoading(false);
    });
  }, []);

  return { tasks, loading };
}
TSX

cat > web/hooks/useAuth.ts << 'TSX'
import { useState, useCallback } from 'react';
import { User } from '../types';

export function useAuth() {
  const [user, setUser] = useState<User | null>(null);

  const login = useCallback(async (email: string, password: string) => {
    const res = await fetch('/api/auth/login', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    });
    const data = await res.json();
    setUser(data.user);
  }, []);

  const logout = useCallback(() => setUser(null), []);

  return { user, login, logout };
}
TSX

cat > web/pages/Dashboard.tsx << 'TSX'
import React from 'react';
import { Header, Sidebar, TaskCard } from '../components';
import { useTasks } from '../hooks/useTasks';

export const Dashboard: React.FC = () => {
  const { tasks, loading } = useTasks();

  if (loading) return <div>Loading...</div>;

  return (
    <div className="dashboard">
      <Header />
      <main>
        <h1>Dashboard</h1>
        <div className="task-grid">
          {tasks.map(t => <TaskCard key={t.id} task={t} onStatusChange={() => {}} />)}
        </div>
      </main>
    </div>
  );
};
TSX

cat > web/pages/TaskList.tsx << 'TSX'
import React, { useState } from 'react';
import { Header, TaskCard, Button, Modal } from '../components';
import { useTasks } from '../hooks/useTasks';

export const TaskList: React.FC = () => {
  const { tasks } = useTasks();
  const [showModal, setShowModal] = useState(false);

  return (
    <div className="task-list-page">
      <Header />
      <main>
        <div className="toolbar">
          <h1>All Tasks</h1>
          <Button onClick={() => setShowModal(true)}>New Task</Button>
        </div>
        <ul className="task-list">
          {tasks.map(t => <TaskCard key={t.id} task={t} onStatusChange={() => {}} />)}
        </ul>
      </main>
      <Modal isOpen={showModal} onClose={() => setShowModal(false)} title="New Task">
        <form>
          <input placeholder="Task title" />
          <Button type="submit">Create</Button>
        </form>
      </Modal>
    </div>
  );
};
TSX

cat > web/pages/Settings.tsx << 'TSX'
import React from 'react';
import { Header, Button } from '../components';

export const Settings: React.FC = () => {
  return (
    <div className="settings-page">
      <Header />
      <main>
        <h1>Settings</h1>
        <section>
          <h2>Profile</h2>
          <form>
            <label>Name</label>
            <input type="text" />
            <label>Email</label>
            <input type="email" />
            <Button type="submit">Save</Button>
          </form>
        </section>
      </main>
    </div>
  );
};
TSX

dd if=/dev/urandom bs=1024 count=25 2>/dev/null | base64 > web/styles.css

# ---- Config folder ----
cat > config/default.json << 'JSON'
{
  "api": {
    "port": 8000,
    "host": "0.0.0.0"
  },
  "database": {
    "pool_size": 10,
    "max_overflow": 20
  },
  "redis": {
    "ttl": 3600
  }
}
JSON

cat > config/production.json << 'JSON'
{
  "api": {
    "port": 80,
    "host": "0.0.0.0"
  },
  "database": {
    "pool_size": 50,
    "max_overflow": 100
  }
}
JSON

# ---- Scripts folder ----
cat > scripts/migrate.sh << 'SH'
#!/bin/bash
set -e
alembic upgrade head
SH

cat > scripts/seed.sh << 'SH'
#!/bin/bash
set -e
python -m api.seeds
SH

# ---- Migrations folder ----
cat > migrations/001_initial.sql << 'SQL'
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE tasks (
    id SERIAL PRIMARY KEY,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    status VARCHAR(50) DEFAULT 'pending',
    owner_id INTEGER REFERENCES users(id),
    created_at TIMESTAMP DEFAULT NOW()
);
SQL

cat > migrations/002_add_projects.sql << 'SQL'
CREATE TABLE projects (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);

ALTER TABLE tasks ADD COLUMN project_id INTEGER REFERENCES projects(id);
SQL

# ---- Root files ----
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

cat > package.json << 'JSON'
{
  "name": "taskflow-web",
  "version": "2.1.0",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "test": "vitest"
  },
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "react-router-dom": "^6.20.0"
  },
  "devDependencies": {
    "typescript": "^5.3.0",
    "vite": "^5.0.0",
    "vitest": "^1.0.0"
  }
}
JSON

cat > tsconfig.json << 'JSON'
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022", "DOM"],
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "jsx": "react-jsx"
  },
  "include": ["web/**/*"]
}
JSON

cat > Dockerfile << 'DOCKER'
FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY api/ ./api/
EXPOSE 8000
CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0"]
DOCKER

cat > docker-compose.yml << 'YAML'
version: '3.8'
services:
  api:
    build: .
    ports:
      - "8000:8000"
    environment:
      - DATABASE_URL=postgresql://postgres:postgres@db/taskflow
    depends_on:
      - db
  db:
    image: postgres:15
    environment:
      - POSTGRES_DB=taskflow
      - POSTGRES_PASSWORD=postgres
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
YAML

cat > .gitignore << 'GI'
__pycache__/
*.pyc
.env
node_modules/
dist/
.vite/
*.log
GI

cat > Makefile << 'MK'
.PHONY: dev test lint build

dev:
	uvicorn api.main:app --reload

test:
	pytest tests/ -v

lint:
	ruff check api/
	mypy api/

build:
	docker-compose build
MK

cat > requirements.txt << 'REQ'
fastapi>=0.109.0
sqlalchemy>=2.0.0
uvicorn>=0.27.0
pydantic>=2.5.0
pydantic-settings>=2.0.0
redis>=5.0.0
alembic>=1.13.0
pytest>=7.4.0
httpx>=0.25.0
REQ

# ========================================
# Set varied file dates and times
# ========================================

# Older files (months ago)
touch -t 202509151430 api/__init__.py
touch -t 202509201015 api/main.py
touch -t 202510050900 api/models.py
touch -t 202510121145 api/routes.py
touch -t 202510181600 api/database.py
touch -t 202511031030 api/config.py
touch -t 202511100845 api/utils.py

# Middleware (weeks ago)
touch -t 202512011400 api/middleware/__init__.py
touch -t 202512031130 api/middleware/auth.py
touch -t 202512051700 api/middleware/logging.py
touch -t 202512081015 api/middleware/cors.py

# Schemas (weeks ago)
touch -t 202512101200 api/schemas/__init__.py
touch -t 202512101230 api/schemas/task.py
touch -t 202512101245 api/schemas/user.py

# Docs (various dates)
touch -t 202510251400 docs/architecture.md
touch -t 202511151030 docs/api-reference.md
touch -t 202512201600 docs/deployment.md
touch -t 202512220900 docs/contributing.md

# Tests (recent)
touch -t 202601051100 tests/__init__.py
touch -t 202601051130 tests/conftest.py
touch -t 202601081430 tests/test_api.py
touch -t 202601081500 tests/test_models.py
touch -t 202601101000 tests/test_auth.py
touch -t 202601121345 tests/test_tasks.py
touch -t 202601121400 tests/test_users.py

# Web - older
touch -t 202510281100 web/App.tsx
touch -t 202510281130 web/index.tsx
touch -t 202511051400 web/api.ts
touch -t 202511051430 web/types.ts
touch -t 202511081015 web/styles.css

# Web components (various)
touch -t 202511121000 web/components/TaskCard.tsx
touch -t 202511121030 web/components/Header.tsx
touch -t 202511151100 web/components/Sidebar.tsx
touch -t 202511181400 web/components/Button.tsx
touch -t 202511201600 web/components/Modal.tsx
touch -t 202511201630 web/components/index.ts

# Web hooks (recent)
touch -t 202512151030 web/hooks/useTasks.ts
touch -t 202512181430 web/hooks/useAuth.ts

# Web pages
touch -t 202511251200 web/pages/Dashboard.tsx
touch -t 202511281100 web/pages/TaskList.tsx
touch -t 202512021400 web/pages/Settings.tsx

# Config and scripts
touch -t 202509101000 config/default.json
touch -t 202511201500 config/production.json
touch -t 202510011200 scripts/migrate.sh
touch -t 202510011230 scripts/seed.sh

# Migrations
touch -t 202509101030 migrations/001_initial.sql
touch -t 202511051100 migrations/002_add_projects.sql

# Root files (various)
touch -t 202509101000 pyproject.toml
touch -t 202509101100 README.md
touch -t 202510281200 package.json
touch -t 202510281230 tsconfig.json
touch -t 202511101000 Dockerfile
touch -t 202511101030 docker-compose.yml
touch -t 202509101000 .gitignore
touch -t 202510151400 Makefile
touch -t 202511051200 requirements.txt

# Initial commit
git add -A
git commit -q -m "Initial commit"

# ========================================
# Create git status variety
# ========================================

# STAGED (green): Modified existing files
echo "# Adding batch operations" >> api/models.py
echo "# Rate limiting" >> api/middleware/auth.py
git add api/models.py api/middleware/auth.py

# MODIFIED (yellow): Changes not staged
echo "// TODO: Add dark mode" >> web/App.tsx
echo "# Fix connection pooling" >> api/database.py
echo "export const VERSION = '2.2.0';" >> web/api.ts

# UNTRACKED (gray): New files not added
cat > api/cache.py << 'PY'
"""Redis cache utilities."""
import redis
from .config import settings

client = redis.Redis.from_url(settings.redis_url)

def get_cached(key: str):
    return client.get(key)

def set_cached(key: str, value: str, ttl: int = 300):
    client.setex(key, ttl, value)
PY

cat > api/notifications.py << 'PY'
"""Notification service."""
import smtplib
from email.mime.text import MIMEText

def send_email(to: str, subject: str, body: str):
    msg = MIMEText(body)
    msg['Subject'] = subject
    msg['To'] = to
    # TODO: Configure SMTP
PY

cat > web/components/Toast.tsx << 'TSX'
import React from 'react';

interface Props {
  message: string;
  type: 'success' | 'error' | 'info';
}

export const Toast: React.FC<Props> = ({ message, type }) => {
  return <div className={`toast toast-${type}`}>{message}</div>;
};
TSX

cat > web/hooks/useLocalStorage.ts << 'TSX'
import { useState, useEffect } from 'react';

export function useLocalStorage<T>(key: string, initial: T) {
  const [value, setValue] = useState<T>(() => {
    const stored = localStorage.getItem(key);
    return stored ? JSON.parse(stored) : initial;
  });

  useEffect(() => {
    localStorage.setItem(key, JSON.stringify(value));
  }, [key, value]);

  return [value, setValue] as const;
}
TSX

cat > tests/test_cache.py << 'PY'
"""Cache tests."""
import pytest
from api.cache import get_cached, set_cached

def test_cache_roundtrip():
    set_cached("test_key", "test_value", ttl=60)
    assert get_cached("test_key") == b"test_value"
PY

cat > CHANGELOG.md << 'MD'
# Changelog

## [2.1.0] - 2026-01-15
### Added
- Project boards feature
- Real-time collaboration via WebSocket

### Fixed
- Task ordering bug
- Memory leak in dashboard
MD

cat > notes.txt << 'TXT'
TODO:
- Add WebSocket support
- Implement project archiving
- Set up CI/CD pipeline
- Write API documentation
TXT

# Set recent dates on new untracked files (today/yesterday)
touch -t 202601200930 api/cache.py
touch -t 202601191400 api/notifications.py
touch -t 202601201015 web/components/Toast.tsx
touch -t 202601181630 web/hooks/useLocalStorage.ts
touch -t 202601200845 tests/test_cache.py
touch -t 202601191100 CHANGELOG.md
touch -t 202601201100 notes.txt

# Set recent dates on modified files
touch -t 202601201045 api/models.py
touch -t 202601200900 api/middleware/auth.py
touch -t 202601191530 web/App.tsx
touch -t 202601200930 api/database.py
touch -t 202601201000 web/api.ts

echo ""
echo "==> Screenshot folders created at: $BASE"
echo ""
echo "Left pane:  $CORP"
echo "Right pane: $DEV"
echo ""
echo "File counts:"
echo "  acme-corp: $(find "$CORP" -type f | wc -l | tr -d ' ') files"
echo "  taskflow:  $(find "$DEV" -type f | wc -l | tr -d ' ') files"
echo ""
echo "Git status in taskflow:"
cd "$DEV" && git status --short
echo ""
echo "==> Open Detours and navigate to these folders"
echo "==> Make sure sidebar is visible (Cmd-0)"
echo "==> Select Budget-2026.xlsx in left pane for highlight"
