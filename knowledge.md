# Project knowledge

This file gives Codebuff context about your project: goals, commands, conventions, and gotchas.

## Overview
Railway Sim — a 2D railway/transport simulation game built with Godot 4.6 (Mobile renderer). A train shuttles passengers between towns, earning money per delivery.

## Quickstart
- Setup: Open `project.godot` in Godot 4.6+
- Dev: Run from Godot editor (F5) — main scene is `node_2d.tscn`
- Test: No automated tests; verify visually in-engine

## Architecture
- `project.godot` — Engine config (app name, main scene, renderer)
- `node_2d.tscn` — Root scene (Node2D) with `main.gd` attached
- `main.gd` — All game logic: passenger generation, train movement, boarding/unboarding, money, and drawing (towns, track, train, HUD)
- `icon.svg` — App icon

## Conventions
- Language: GDScript
- Formatting: Godot default (tabs, snake_case)
- Drawing: Uses `_draw()` + `queue_redraw()` for rendering (no separate sprite nodes yet)
- Patterns to follow: Keep logic in `_process(delta)`, rendering in `_draw()`
- Things to avoid: Don't edit `.godot/` or `.import` files by hand; use the Godot editor for scene/resource changes
