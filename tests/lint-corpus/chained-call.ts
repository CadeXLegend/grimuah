export const g = (v: unknown): unknown => v;
export const f = (y: unknown): number => g(y as string) as number;
