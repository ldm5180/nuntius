--  The one step of the websocket upgrade that cannot be proved: the
--  accept key is a SHA-1 digest, and GNAT.SHA1 is not SPARK.  The
--  parse of the four upgrade headers and the 101 head itself stay in
--  Nuntius.Web, beside the rest of the request parser.

package Nuntius.Web.Handshake is

   --  RFC 6455 4.2.2: base64 (SHA-1 (Key || the protocol's GUID)).
   function Accept_Key (Key : String) return String
   with
     Pre  => Key'Length = Ws_Key_Length,
     Post => Accept_Key'Result'Length = Accept_Length;

end Nuntius.Web.Handshake;
