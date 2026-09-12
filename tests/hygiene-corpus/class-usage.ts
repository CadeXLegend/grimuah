import { InvoicingMode, TimeFormat } from "./settings.types";
export class Holder {
  readonly InvoicingMode = InvoicingMode;
  setTimeFormat(format: string): void {
    this.update({ timeFormat: format as TimeFormat });
  }
  update(value: unknown): void {
    void value;
  }
}
