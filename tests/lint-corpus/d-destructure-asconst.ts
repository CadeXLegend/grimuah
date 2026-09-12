export const f = (o: { a: number }): void => {
  const { a } = { a: 1 } as const;
  void a;
  void o;
};
