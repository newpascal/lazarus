{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit SemaphorGridLPK;

{$warn 5023 off : no warning about unused units}
interface

uses
  SemaphorGrids, SemaphorDBGrids, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('SemaphorGrids', @SemaphorGrids.Register);
  RegisterUnit('SemaphorDBGrids', @SemaphorDBGrids.Register);
end;

initialization
  RegisterPackage('SemaphorGridLPK', @Register);
end.
