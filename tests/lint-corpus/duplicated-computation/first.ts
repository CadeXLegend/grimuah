export const tail = (remainder: string, separatorIndex: number): string =>
  remainder
    .slice(separatorIndex + 1);
