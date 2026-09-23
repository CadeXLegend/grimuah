// an optional method signature in an object type, and an optional member of a
// class body. the property form belongs to `optional-property` and the parameter
// form to `optional-parameter`, so these are the two neither of those reads: the
// object type member holds a call signature rather than one type expression, and a
// class body is a container the type model never walks. every layer is on, so
// nothing else here is a banned construct

export type Handlers = {
  readonly onReady?(count: number): void;
  readonly onDone(count: number): void;
};

export class Client {
  readonly label?: string;
  readonly name: string = "";

  ready?(): void {}

  stop(): void {}
}
