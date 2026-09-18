with Ada.Streams;
use type Ada.Streams.Stream_Element_Offset;

with GNAT.SHA1;

with Nuntius.Rfc6455;

package body Nuntius.Web.Handshake is

   Guid : constant String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

   function Accept_Key (Key : String) return String is
      --  Bound to the binary digest first: GNAT.SHA1.Digest is
      --  overloaded on its return type.
      D : constant GNAT.SHA1.Binary_Message_Digest :=
        GNAT.SHA1.Digest (Key & Guid);
      O : Nuntius.Rfc6455.Octets (1 .. D'Length);
   begin
      for K in O'Range loop
         O (K) :=
           Nuntius.Rfc6455.Octet
             (D (D'First + Ada.Streams.Stream_Element_Offset (K - O'First)));
      end loop;
      return Nuntius.Rfc6455.Base64 (O);
   end Accept_Key;

end Nuntius.Web.Handshake;
