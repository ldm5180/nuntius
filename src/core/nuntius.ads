--  Nuntius: narrow client-side transport ports -- the HTTP verbs and
--  websocket frames a hexagonal application needs -- with production
--  adapters (libcurl via utilada, the AWS crate's client-side websocket)
--  and a SPARK-proven bounded frame FIFO behind the websocket adapter.
--  The ports are deliberately tiny, so consumers test against scripted
--  fakes fully offline and swap adapters without touching callers.

package Nuntius
  with Pure, SPARK_Mode
is

end Nuntius;
