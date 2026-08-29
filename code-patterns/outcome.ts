/**
 * generic outcome pattern for graceful error handling without throws
 *
 * every function that can fail returns a discriminated union:
 * - { succeeded: true, result: T } on success
 * - { succeeded: false, reason: TFailureReason } on failure
 *
 * callers must narrow on `succeeded` before accessing `result`
 * no function in the codebase may throw, all errors flow through this type
 */

/* ── type definitions ─────────────────────────────────────────── */

export type Success<T> = [T] extends [void | undefined]
  ? { readonly succeeded: true }
  : { readonly succeeded: true; readonly result: T };

export type Failure<TReason extends string, T = void> = [T] extends [
  void | undefined,
]
  ? { readonly succeeded: false; readonly reason: TReason }
  : { readonly succeeded: false; readonly reason: TReason; readonly result: T };

export type Outcome<
  TFailureReason extends string,
  TSuccess = void,
  TData = void,
> = Success<TSuccess> | Failure<TFailureReason, TData>;

/* ── generic failure reasons ──────────────────────────────────── */

export enum ArrayFailureReason {
  IndexOutOfBounds = "IndexOutOfBounds",
  EmptyArray = "EmptyArray",
}

export enum OperationFailureReason {
  NotFound = "NotFound",
  ValidationError = "ValidationError",
  ApiError = "ApiError",
  Timeout = "Timeout",
}

export enum InputFailureReason {
  EmptyValue = "EmptyValue",
  InvalidFormat = "InvalidFormat",
}

/* ── helper: array bounds ─────────────────────────────────────── */

export const isIndexWithinArrayBounds = (
  array: readonly unknown[],
  index: number,
): boolean => index >= 0 && index < array.length;

/* ── helper: is-success type guard ────────────────────────────── */

export const isSuccess = <TFailureReason extends string, TSuccess>(
  outcome: Outcome<TFailureReason, TSuccess>,
): outcome is Success<TSuccess> => outcome.succeeded;

/* ── helper: safe JSON parsing, never throws ─────────────────── */

export enum JsonParseFailureReason {
  InvalidJson = "InvalidJson",
}

export type SafeJsonParseOutcome<T> =
  | { readonly succeeded: true; readonly result: T }
  | {
      readonly succeeded: false;
      readonly reason: JsonParseFailureReason.InvalidJson;
    };

/**
 * parse JSON without throwing, returns a discriminated union
 * use this for any string that originates from the database or external input
 */
export const safeJsonParse = <T = unknown>(
  raw: string,
): SafeJsonParseOutcome<T> => {
  try {
    const parsed: T = JSON.parse(raw) as T;
    return { succeeded: true, result: parsed };
  } catch {
    return { succeeded: false, reason: JsonParseFailureReason.InvalidJson };
  }
};
