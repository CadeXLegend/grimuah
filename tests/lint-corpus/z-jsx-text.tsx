export const C = (): unknown => (
  <div>null and switch and throw and let and ==</div>
);
export const D = (props: { readonly n: number | null }): unknown => (
  <span>{props.n as any}</span>
);
