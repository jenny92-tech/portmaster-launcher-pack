# INPUT: synthetic LocManager and the source-bound language IL transformer
# OUTPUT: CLR execution of original and restricted language selection
# POS: verifies list, fallback, rejection and idempotence without game code
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'ports/sts2/src/tools/dll_surgery/official_runtime'
DOTNET = os.environ.get('STS2_PATCH_DOTNET')
GAME = r'''
using System.Globalization;
namespace MegaCrit.Sts2.Core.Localization {
 public class LocManager {
  public static List<string> Languages { get; } = ["eng","zhs","zht","deu","esp","fra","ita","jpn","kor","pol","ptb","rus","spa","tha","tur"];
  public static CultureInfo English { get; } = CultureInfo.GetCultureInfo("en");
 }
}
public static class Program {
 public static void Main(string[] args) {
  var list=MegaCrit.Sts2.Core.Localization.LocManager.Languages;
  var saved=args[0]; var selected=list.Contains(saved) ? saved : "eng";
  Console.WriteLine(string.Join(",",list)+"|"+selected+"|"+MegaCrit.Sts2.Core.Localization.LocManager.English.Name);
 }
}
'''
PATCHER = r'''
using Mono.Cecil;
using Mono.Cecil.Cil;
using var game=AssemblyDefinition.ReadAssembly(args[0]);
if (args[2] == "bad") {
 var c=game.MainModule.GetType("MegaCrit.Sts2.Core.Localization.LocManager").Methods.Single(m=>m.Name==".cctor");
 c.Body.Instructions.Single(i=>i.OpCode==OpCodes.Ldstr && (string)i.Operand=="jpn").Operand="broken";
 try { LanguageRestrictionHooks.Inject(game); throw new Exception("invalid list accepted"); }
 catch (InvalidOperationException) { Console.WriteLine("rejected"); return; }
}
LanguageRestrictionHooks.Inject(game);
try { LanguageRestrictionHooks.Inject(game); throw new Exception("duplicate accepted"); }
catch (InvalidOperationException) { }
game.Write(args[1]);
using var original=AssemblyDefinition.ReadAssembly(args[0]);
using var check=AssemblyDefinition.ReadAssembly(args[1]); LanguageRestrictionHooks.VerifyOtherMethods(original,check);
var unrelated=check.MainModule.GetType("Program").Methods.Single(m=>m.Name=="Main");
unrelated.Body.Instructions.Insert(0,Instruction.Create(OpCodes.Nop));
try { LanguageRestrictionHooks.VerifyOtherMethods(original,check); throw new Exception("unrelated change accepted"); }
catch (InvalidOperationException) { }
'''

@unittest.skipUnless(DOTNET, 'set STS2_PATCH_DOTNET to a .NET 9 SDK')
class TwoLanguagesTests(unittest.TestCase):
    def test_restricted_list_fallback_and_invalid_input(self):
        cecil = TOOL / 'bin/Release/net9.0/Mono.Cecil.dll'
        with tempfile.TemporaryDirectory(prefix='sts2-two-languages-') as tmp:
            p = Path(tmp); (p/'game').mkdir(); (p/'patcher').mkdir()
            (p/'NuGet.Config').write_text('<configuration><packageSources><clear/></packageSources></configuration>')
            q = lambda x: escape(str(x), {'"': '&quot;'})
            props = '<PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net9.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Optimize>true</Optimize></PropertyGroup>'
            (p/'game/game.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk">'+props+'</Project>')
            (p/'game/Program.cs').write_text(GAME)
            (p/'patcher/patcher.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk">'+props+'<ItemGroup><Reference Include="Mono.Cecil"><HintPath>'+q(cecil)+'</HintPath></Reference><Compile Include="'+q(TOOL/'LanguageRestrictionHooks.cs')+'" Link="Hooks.cs"/></ItemGroup></Project>')
            (p/'patcher/Program.cs').write_text(PATCHER)
            env = dict(os.environ, DOTNET_CLI_HOME=str(p/'cli'), DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false')
            for project in ('game','patcher'):
                subprocess.run([DOTNET,'build',str(p/project),'-c','Release','--nologo','-v:q','-p:NuGetAudit=false','-p:RestoreConfigFile='+str(p/'NuGet.Config')],env=env,check=True,capture_output=True,text=True)
            game=p/'game/bin/Release/net9.0/game.dll'; patched=game.with_name('patched.dll'); patcher=p/'patcher/bin/Release/net9.0/patcher.dll'
            original=subprocess.run([DOTNET,str(game),'jpn'],env=env,check=True,capture_output=True,text=True).stdout
            self.assertIn('jpn',original); self.assertIn('|jpn|en',original)
            bad=subprocess.run([DOTNET,str(patcher),str(game),str(patched),'bad'],env=env,check=True,capture_output=True,text=True)
            self.assertIn('rejected',bad.stdout); self.assertFalse(patched.exists())
            subprocess.run([DOTNET,str(patcher),str(game),str(patched),'ok'],env=env,check=True,capture_output=True,text=True)
            patched.replace(game)
            for saved,expected in [('eng','eng'),('zhs','zhs'),('jpn','eng'),('zht','eng'),('','eng')]:
                result=subprocess.run([DOTNET,str(game),saved],env=env,check=True,capture_output=True,text=True)
                self.assertEqual(result.stdout.strip(),f'eng,zhs|{expected}|en')
