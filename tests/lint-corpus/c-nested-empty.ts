export const f = (): void => {
  try {
    JSON.parse("{}");
  } catch {
    try {
      JSON.parse("[]");
    } catch {}
  }
};
