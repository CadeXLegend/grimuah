export const f = (): void => {
  try {
    JSON.parse("{}");
  } catch {
    if (Math.random() > 0.5) {
      return;
    }
  }
};
