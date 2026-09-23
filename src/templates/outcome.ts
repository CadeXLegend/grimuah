/**
 * generic outcome pattern for graceful error handling without throws
 *
 * every function that can fail returns a discriminated union:
 * - { succeeded: true, result: T } on success
 * - { succeeded: false, reason: TFailureReason } on failure
 *
 * callers must narrow on `succeeded` before accessing `result`
 * no function in the codebase may throw, all errors flow through this type
 *
 * the pattern carries the absence case as well, so a value that may be missing
 * is an Outcome instead of a null or an optional property
 */

/* ── type definitions ─────────────────────────────────────────── */

// void and undefined both mean "no value", the tuple check avoids distributive
// conditional evaluation on unions
// TEmpty lives in a type parameter default because the lint rules ban the void
// token in other type positions
type IsEmptyValue<T, TEmpty = void> = [T] extends [TEmpty] ? true : false;

// the four members are plain object types and the conditional selection lives on
// the exported aliases below, never inside a member
// a conditional inside a member stays unresolved while its type parameter is
// generic, which makes `.result` unreachable from any generic helper
export type SuccessWithValue<TSuccess> = {
  readonly succeeded: true;
  readonly result: TSuccess;
};

export type SuccessEmpty = { readonly succeeded: true };

export type FailureWithReason<TFailureReason extends string> = {
  readonly succeeded: false;
  readonly reason: TFailureReason;
};

export type FailureWithData<TFailureReason extends string, TData> = {
  readonly succeeded: false;
  readonly reason: TFailureReason;
  readonly result: TData;
};

// the aliases a generic signature is written against, they default TData to void
// so the selection resolves at declaration time even when TFailureReason is generic
// a generic parameter typed as `Outcome<R, T>` keeps its selection deferred and no
// helper can read `.result` through it, so a generic signature names the branch it
// means: ValuedOutcome when the success carries a value, EmptyOutcome when it does not
export type ValuedOutcome<
  TFailureReason extends string,
  TSuccess,
  TData = void,
> = SuccessWithValue<TSuccess> | Failure<TFailureReason, TData>;

export type EmptyOutcome<
  TFailureReason extends string,
  TData = void,
> = SuccessEmpty | Failure<TFailureReason, TData>;

// the alias a caller writes in a signature, identical in shape to the bare
// union it replaces
export type Success<TSuccess> =
  IsEmptyValue<TSuccess> extends true
    ? SuccessEmpty
    : SuccessWithValue<TSuccess>;

export type Failure<TFailureReason extends string, TData = void> =
  IsEmptyValue<TData> extends true
    ? FailureWithReason<TFailureReason>
    : FailureWithData<TFailureReason, TData>;

export type Outcome<
  TFailureReason extends string,
  TSuccess = void,
  TData = void,
> =
  IsEmptyValue<TSuccess> extends true
    ? EmptyOutcome<TFailureReason, TData>
    : ValuedOutcome<TFailureReason, TSuccess, TData>;

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

// the absence vocabulary, so a missing value reads the same at every surface
// instead of each one inventing its own word for nothing being there
export enum AbsenceFailureReason {
  Missing = "Missing",
  NotConfigured = "NotConfigured",
}

/* ── helper: array bounds ─────────────────────────────────────── */

export const isIndexWithinArrayBounds = (
  array: readonly unknown[],
  index: number,
): boolean => index >= 0 && index < array.length;

/* ── helper: is-success type guard ────────────────────────────── */

/**
 * narrow a valued outcome to its success member
 * an empty outcome needs no guard, its success member carries nothing to read, so
 * this accepts only the valued branch and refuses to promise a `result` that an
 * empty success never had
 */
export const isSuccess = <TFailureReason extends string, TSuccess>(
  outcome: ValuedOutcome<TFailureReason, TSuccess>,
): outcome is SuccessWithValue<TSuccess> => outcome.succeeded;

/* ── helper: absence adapters ─────────────────────────────────── */

/**
 * lift a value that may be absent into an outcome, the seam between an optional
 * source and this pattern
 * use it where the value enters, a map lookup, a parsed row, a config read, then
 * keep the value an Outcome inward
 * the parameter is `undefined` rather than `null` because this file is itself
 * linted, and a null from a third-party boundary converts with `row ?? undefined`
 */
export const fromUndefined = <TFailureReason extends string, TSuccess>(
  value: TSuccess | undefined,
  reason: TFailureReason,
): ValuedOutcome<TFailureReason, TSuccess> =>
  value === undefined
    ? { succeeded: false, reason }
    : { succeeded: true, result: value };

/**
 * read the value or fall back, the replacement for a defaulted optional property
 * the fallback may be another type, so `undefined` here is the deliberate escape
 * hatch back to an optional value at a third-party boundary
 * an empty outcome has no value to read, so it takes the fallback as well, which
 * makes this total over every outcome shape
 */
export const getOrElse = <TFailureReason extends string, TSuccess, TFallback>(
  outcome: ValuedOutcome<TFailureReason, TSuccess> | SuccessEmpty,
  fallback: TFallback,
): TSuccess | TFallback =>
  outcome.succeeded && "result" in outcome ? outcome.result : fallback;

export type OutcomeHandlers<
  TFailureReason extends string,
  TSuccess,
  TMapped,
> = {
  readonly onSuccess: (result: TSuccess) => TMapped;
  readonly onFailure: (reason: TFailureReason) => TMapped;
};

/**
 * read both branches in one expression, for a call site that would otherwise
 * write an if/return pair, and for a dispatch table keyed on the outcome
 * both handlers receive a value, so this covers the valued branch only
 */
export const matchOutcome = <
  TFailureReason extends string,
  TSuccess,
  TMapped,
>(
  outcome: ValuedOutcome<TFailureReason, TSuccess>,
  handlers: OutcomeHandlers<TFailureReason, TSuccess, TMapped>,
): TMapped =>
  outcome.succeeded
    ? handlers.onSuccess(outcome.result)
    : handlers.onFailure(outcome.reason);

/* ── helper: exception boundary, never throws ─────────────────── */

/**
 * run an operation that may throw and turn the throw into a failure
 * the caller supplies the reason, because a caught value is `unknown` and this
 * pattern reports failures as named strings rather than as raw errors
 * the catch returns an outcome, so it is the one try/catch that needs no log
 */
export const attempt = <TFailureReason extends string, TSuccess>(
  operation: () => TSuccess,
  reason: TFailureReason,
): ValuedOutcome<TFailureReason, TSuccess> => {
  try {
    return { succeeded: true, result: operation() };
  } catch {
    return { succeeded: false, reason };
  }
};

/**
 * the await boundary, for a promise that may reject
 * pass the promise itself rather than a thunk, the await attaches its rejection
 * handler in the same tick so the rejection is never unhandled
 */
export const attemptAsync = async <TFailureReason extends string, TSuccess>(
  operation: Promise<TSuccess>,
  reason: TFailureReason,
): Promise<ValuedOutcome<TFailureReason, TSuccess>> => {
  try {
    return { succeeded: true, result: await operation };
  } catch {
    return { succeeded: false, reason };
  }
};

/* ── helper: safe JSON parsing, never throws ─────────────────── */

export enum JsonParseFailureReason {
  InvalidJson = "InvalidJson",
}

export type SafeJsonParseOutcome<T> = ValuedOutcome<JsonParseFailureReason, T>;

/**
 * parse JSON without throwing, returns a discriminated union
 * use this for any string that originates from the database or external input
 */
export const safeJsonParse = <T = unknown>(
  raw: string,
): SafeJsonParseOutcome<T> =>
  attempt(() => JSON.parse(raw) as T, JsonParseFailureReason.InvalidJson);
