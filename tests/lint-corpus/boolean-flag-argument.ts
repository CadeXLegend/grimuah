// a bare boolean at a call site, which reads the same whichever flag it asked
// for. the corpus is linted with every layer on, so nothing here is a banned
// construct

export const ConsentRow = buildConsentButtonRow(false);

export const MarriedRole = patchMemberMarriedRole(true);

export const NamedFlag = patchMemberMarriedRole(wantsMarried);

export const Constructed = new Panel(true);
