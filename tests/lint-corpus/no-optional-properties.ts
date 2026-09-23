// an optional property and an optional parameter, and the shapes both rules
// leave alone. a property is a member of an object type: in an interface, in a
// type literal, nested inside another object type, in an `as` assertion's type
// and inside a `declare module` block, which the reader has to scan for its
// declarations. a parameter is optional on a function and on a constructor
// alike, and the class field at the bottom is a third container, reported by
// `optional-class-member` because the type model never reads a class body. every
// layer is on, so nothing else is banned and every type literal member is readonly

export interface MessageDraft {
  readonly channel?: string;
  readonly body: string;
}

export type DraftOptions = {
  readonly retries?: number;
  readonly nested: { readonly tag?: string };
};

export function fill(draft: MessageDraft, suffix?: string): MessageDraft {
  return { ...draft, body: draft.body + (suffix ?? "") };
}

export function decode(raw: unknown): unknown {
  return raw as { readonly body?: string };
}

declare module "shim" {
  export interface ShimEntry {
    readonly tag?: string;
  }
}

export class DraftHolder {
  readonly channel?: string;

  constructor(channel?: string) {
    this.channel = channel;
  }
}
