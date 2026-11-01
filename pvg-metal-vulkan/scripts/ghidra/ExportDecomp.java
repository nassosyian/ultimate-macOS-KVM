// Export decompiled C for every function, plus defined strings, to text files.
// Usage (headless): -postScript ExportDecomp.java <out_dir> [name_regex]
// Writes <out_dir>/<program>.c and <out_dir>/<program>.strings.tsv
// @category Export
import java.io.File;
import java.io.PrintWriter;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

public class ExportDecomp extends GhidraScript {
    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        File outDir = new File(args.length > 0 ? args[0] : ".");
        java.util.regex.Pattern filter = args.length > 1 ? java.util.regex.Pattern.compile(args[1]) : null;
        outDir.mkdirs();
        String name = currentProgram.getName().replaceAll("[^A-Za-z0-9._-]", "_");

        DecompInterface ifc = new DecompInterface();
        ifc.setOptions(new DecompileOptions());
        ifc.openProgram(currentProgram);

        int done = 0, failed = 0;
        try (PrintWriter out = new PrintWriter(new File(outDir, name + ".c"))) {
            FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
            while (it.hasNext() && !monitor.isCancelled()) {
                Function f = it.next();
                if (f.isExternal() || f.isThunk()) {
                    continue;
                }
                if (filter != null && !filter.matcher(f.getName(true)).find()) {
                    continue;
                }
                out.printf("// ===== %s @ %s =====%n", f.getName(true), f.getEntryPoint());
                DecompileResults r = ifc.decompileFunction(f, 120, monitor);
                if (r != null && r.decompileCompleted()) {
                    out.println(r.getDecompiledFunction().getC());
                    done++;
                } else {
                    out.println("// decompilation failed: " + (r == null ? "null" : r.getErrorMessage()));
                    failed++;
                }
            }
        }
        ifc.dispose();

        try (PrintWriter out = new PrintWriter(new File(outDir, name + ".strings.tsv"))) {
            DataIterator it = currentProgram.getListing().getDefinedData(true);
            while (it.hasNext()) {
                Data d = it.next();
                if (d.hasStringValue()) {
                    out.printf("%s\t%s%n", d.getAddress(), String.valueOf(d.getValue()).replace("\n", "\\n"));
                }
            }
        }
        println(String.format("ExportDecomp: %s: %d functions decompiled, %d failed", name, done, failed));
    }
}
