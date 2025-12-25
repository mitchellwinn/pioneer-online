# Camera System Plugin

Provides multiple camera types for 3D games with a unified base class system.

## Features

- **BaseCamera**: Minimal base class for camera zone management
- **FollowCamera**: Full-featured camera with vantage angle, deadzone, and look constraints
- **ThirdPersonCamera**: Over-shoulder camera with right stick orbital rotation

## Required Input Actions

Add these input actions in **Project → Project Settings → Input Map**:

- `camera_rotate_right` / `camera_rotate_left` (Right Stick X)
- `camera_rotate_up` / `camera_rotate_down` (Right Stick Y)

## Usage

- Use `FollowCamera` for top-down/isometric follow cameras
- Use `ThirdPersonCamera` for action/adventure style orbital cameras

## Integration

- Verifies required input actions on load and warns if any are missing.
- Designed to work with **Multimedia Zones** and other gsg plugins.
