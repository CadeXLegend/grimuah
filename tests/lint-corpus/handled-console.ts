export const f = (): void => {
  try {
    JSON.parse("{}");
  } catch {
    console.error("bad");
  }
};
