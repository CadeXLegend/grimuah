declare const cond: boolean;
let prefixInc = 0;
void `${++prefixInc}`;
let postfixInc = 0;
postfixInc++;
let prefixDec = 0;
--prefixDec;

class Holder {
  invalid = false;
  touched(): void {}
  render(format: number): void {
    if (this.invalid) {
      this.touched();
      return;
    }
    const data = 1;
    switch (format) {
      case 1:
        this.consume(data);
        break;
      case 2:
        this.consume(data);
        break;
    }
  }
  consume(value: number): void {
    void value;
  }
}
