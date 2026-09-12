// `any[]` casts away type safety exactly as the bare form does, so the matcher
// reads the type the cast names rather than its exact text
export const f = (y: unknown): string[] => y as any[];
