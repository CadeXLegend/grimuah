// an optional property, in an interface, in a type literal, nested inside
// another object type, in an `as` assertion's type and inside a `declare module`
// block, which the reader has to scan for its declarations. the shapes the rule
// must leave alone sit here too: an optional parameter, an optional class field,
// which is a property declaration rather than a signature, and an optional
// method, which is a signature without a property. the corpus is linted with
// every layer on, so nothing here is a banned construct and every property in a
// type literal is readonly

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
