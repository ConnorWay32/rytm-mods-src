// Disassemble a range, forcing disassembly of undefined bytes: DisasmRange <start> <end>
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;

public class DisasmRange extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        Address start = currentProgram.getAddressFactory().getAddress(a[0]);
        Address end   = currentProgram.getAddressFactory().getAddress(a[1]);
        Listing l = currentProgram.getListing();
        Address p = start;
        while (p.compareTo(end) <= 0) {
            if (l.getInstructionAt(p) == null) disassemble(p);
            Instruction i = l.getInstructionAt(p);
            if (i == null) { println(p + ":  <undefined>"); p = p.add(2); continue; }
            println(i.getAddress() + ":  " + i.toString());
            p = p.add(i.getLength());
        }
    }
}
