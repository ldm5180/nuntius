with Ada.Streams.Stream_IO;

package body Nuntius.Web.Files is

   use Ada.Strings.Unbounded;

   procedure Read_Capped
     (Path      : String;
      Max_Bytes : Positive;
      Content   : out Ada.Strings.Unbounded.Unbounded_String;
      Result    : out Read_Result)
   is
      use Ada.Streams.Stream_IO;
      use type Ada.Streams.Stream_Element_Offset;
      F : File_Type;
   begin
      Result := Missing;
      Content := Null_Unbounded_String;
      Open (F, In_File, Path);
      if Size (F) > Ada.Streams.Stream_IO.Count (Max_Bytes) then
         Close (F);
         Result := Oversized;
         return;
      end if;
      declare
         Buf  :
           Ada.Streams.Stream_Element_Array
             (1 .. Ada.Streams.Stream_Element_Offset (Size (F)));
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Read (F, Buf, Last);
         Close (F);
         for K in 1 .. Last loop
            Append (Content, Character'Val (Buf (K)));
         end loop;
      end;
      Result := Read_Ok;
   exception
      when others =>
         begin
            if Is_Open (F) then
               Close (F);
            end if;
         exception
            when others =>
               null;
         end;
         Content := Null_Unbounded_String;
         Result := Missing;
   end Read_Capped;

end Nuntius.Web.Files;
