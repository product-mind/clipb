// Records survive an extension reload (Alt+Shift+R, version updates), so one
// only counts while it was written after the last browser start.
function liveRecord(record, boot) {
  return !!record && record.time >= (boot || 0);
}
