export const a = (x: unknown): string => x as string;
const b = 1;
export const c = (y: unknown): number => y as number as number;
