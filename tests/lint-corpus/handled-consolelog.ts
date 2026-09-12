export const f = (): void => {
  try {
    JSON.parse("{}");
  } catch {
    console.log("bad");
  }
};
