private with Ada.Finalization;
private with System;

--  Production async adapter over libcurl's multi interface, bound
--  directly (utilada wraps only the synchronous easy interface).  One
--  Curl_Client owns one multi handle and a fixed slot table; it is
--  single-owner by design -- exactly one task Starts, Pumps and Cancels
--  on it (libcurl forbids sharing a multi handle across threads).
--  curl_global_init runs at elaboration (single-threaded, and libcurl
--  refcounts it alongside utilada's Register).

package Nuntius.Http.Fetch.Curl is

   --  Concurrent transfers the table holds; a full table refuses Start
   --  with No_Request.
   Max_In_Flight : constant := 64;

   --  Reply bytes beyond this abort the transfer and surface it as a
   --  transport failure -- never a silently truncated body.
   Max_Reply_Bytes : constant := 4 * 1024 * 1024;

   type Curl_Client is limited new Client with private;

   overriding
   procedure Start
     (Self : in out Curl_Client; R : Request; Id : out Request_Id);

   overriding
   procedure Pump
     (Self : in out Curl_Client; Done : out Completion; Got : out Boolean);

   overriding
   procedure Cancel (Self : in out Curl_Client; Id : Request_Id);

   overriding
   function In_Flight (Self : Curl_Client) return Natural;

   --  One curl_multi_poll call: the multi's transfer sockets plus
   --  Extra, up to Timeout_Ms.  With nothing to watch it sleeps the
   --  full timeout (curl_multi_poll's improvement over the
   --  instantly-returning curl_multi_wait).
   overriding
   procedure Wait
     (Self : in out Curl_Client; Timeout_Ms : Natural; Extra : Fd_List);

private

   --  One in-flight transfer: the easy handle, its header list, and the
   --  accumulating response.  Slots are aliased and the client is
   --  limited, so a slot's address is stable for the write callbacks.
   type Slot is record
      Used     : Boolean := False;
      Easy     : System.Address := System.Null_Address;
      Headers  : System.Address := System.Null_Address;  --  curl_slist
      Id       : Request_Id := No_Request;
      Reply    : Unbounded_String;
      Location : Unbounded_String;
      Overflow : Boolean := False;
   end record;

   type Slot_Table is array (1 .. Max_In_Flight) of aliased Slot;

   type Curl_Client is limited
     new Ada.Finalization.Limited_Controlled
     and Client
   with record
      Multi   : System.Address := System.Null_Address;  --  lazy multi_init
      Slots   : Slot_Table;
      Live    : Natural := 0;
      Next_Id : Request_Id := 1;
   end record;

   --  Rundown without task abort: drop every transfer, then the multi
   --  handle.  Idempotent (masters may finalize more than once).
   overriding
   procedure Finalize (Self : in out Curl_Client);

end Nuntius.Http.Fetch.Curl;
