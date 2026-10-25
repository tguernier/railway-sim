// Minimal test harness mirroring the Godot suite's TestBase: suites register
// named tests with t(); assertions count passes/failures and print detail on
// failure only.
import { Vec2 } from '../src/vec2.js';

export const results = { pass: 0, fail: 0 };

function show(v) {
  if (v instanceof Vec2) return `(${v.x.toFixed(2)}, ${v.y.toFixed(2)})`;
  if (v === null) return 'null';
  if (typeof v === 'object') return v.constructor?.name ?? 'object';
  return String(v);
}

export function suite(name) {
  console.log(`[${name}]`);
}

export function t(name, fn) {
  const prev = results.fail;
  try {
    fn();
  } catch (e) {
    results.fail++;
    console.error(`        -> threw: ${e.stack}`);
  }
  console.log(`  ${results.fail === prev ? 'pass' : 'FAIL'}  ${name}`);
}

export function check(cond, msg) {
  if (cond) {
    results.pass++;
  } else {
    results.fail++;
    console.error(`        -> ${msg}`);
  }
}

export function eq(actual, expected) {
  const same = actual instanceof Vec2 && expected instanceof Vec2
    ? actual.equals(expected)
    : actual === expected;
  check(same, `expected ${show(expected)}, got ${show(actual)}`);
}

export function approx(actual, expected, tol = 1.0) {
  check(Math.abs(actual - expected) <= tol,
    `expected ~${expected.toFixed(2)} (±${tol.toFixed(2)}), got ${actual.toFixed(2)}`);
}

export function gt(actual, threshold) {
  check(actual > threshold, `expected ${actual} > ${threshold}`);
}

export function isTrue(cond) {
  check(cond, 'expected true');
}

export function isFalse(cond) {
  check(!cond, 'expected false');
}

export const V = (x, y) => new Vec2(x, y);
