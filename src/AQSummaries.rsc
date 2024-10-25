Macro "AQ Summaries" (Args)
    ret_value = 1
    out_dir  = Args.[Output Folder]
    output_dir = out_dir + "/_summaries/AirQuality"
    if GetDirectoryInfo(output_dir, "All") = null then CreateDirectory(output_dir)
    periods = Args.Periods
    db = Args.Links
    abba = {"AB", "BA"}
    LineM = CreateObject("Table", {FileName: db, LayerType: "Line"})
    fields = {
        {FieldName: "Urban_Code", Type: "Integer", Description: "1 = urban, 0 = rural"}}
    for per in periods do
        fields = fields + {{FieldName: "AB_SpeedCategory_" + per, Description: "AB Speed Category for AQ Analysis (1-16) for 7.5 to 72.5mph in 5mph increments for " + per}, 
                {FieldName: "BA_SpeedCategory_" + per, Description: "BA Speed Category for AQ Analysis (1-16) for 7.5 to 72.5mph in 5mph increments for " + per}}
    end
    LineM.AddFields({Fields: fields})
    LineM.Urban_Code = if Upper(LineM.AreaType) = "DOWNTOWN" or Upper(LineM.AreaType) = "URBAN" then 1 else 2

    for per in periods do
        LineM.("AB_SpeedCategory_"+per) = if LineM.("AB_Speed_"+per) = null then null else if LineM.("AB_Speed_"+per) <= 2.5 then 1 else if LineM.("AB_Speed_"+per) < 7.5 then 2 
            else if LineM.("AB_Speed_"+per) < 12.5 then 3 else if LineM.("AB_Speed_"+per) < 17.5 then 4 else if LineM.("AB_Speed_"+per) < 22.5 then 5 
            else if LineM.("AB_Speed_"+per) < 27.5 then 6 else if LineM.("AB_Speed_"+per) < 32.5 then 7 else if LineM.("AB_Speed_"+per) < 37.5 then 8 
            else if LineM.("AB_Speed_"+per) < 42.5 then 9 else if LineM.("AB_Speed_"+per) < 47.5 then 10 else if LineM.("AB_Speed_"+per) < 52.5 then 11 
            else if LineM.("AB_Speed_"+per) < 57.5 then 12 else if LineM.("AB_Speed_"+per) < 62.5 then 13 else if LineM.("AB_Speed_"+per) < 67.5 then 14 
            else if LineM.("AB_Speed_"+per) < 72.5 then 15 else 16
        LineM.("BA_SpeedCategory_"+per) = if LineM.("BA_Speed_"+per) = null then null else if LineM.("BA_Speed_"+per) <= 2.5 then 1 else if LineM.("BA_Speed_"+per) < 7.5 then 2 
               else if LineM.("BA_Speed_"+per) < 12.5 then 3 else if LineM.("BA_Speed_"+per) < 17.5 then 4 else if LineM.("BA_Speed_"+per) < 22.5 then 5 
               else if LineM.("BA_Speed_"+per) < 27.5 then 6 else if LineM.("BA_Speed_"+per) < 32.5 then 7 else if LineM.("BA_Speed_"+per) < 37.5 then 8 
               else if LineM.("BA_Speed_"+per) < 42.5 then 9 else if LineM.("BA_Speed_"+per) < 47.5 then 10 else if LineM.("BA_Speed_"+per) < 52.5 then 11 
               else if LineM.("BA_Speed_"+per) < 57.5 then 12 else if LineM.("BA_Speed_"+per) < 62.5 then 13 else if LineM.("BA_Speed_"+per) < 67.5 then 14 
               else if LineM.("BA_Speed_"+per) < 72.5 then 15 else 16
    end
    lnview = LineM.GetView()
         dbin = db
   
        Line = CreateObject("Table", {FileName: dbin, LayerType: "Line"})
        tmpfiles = null
        mfile = Args.AQAssign
        pthm = SplitPath(mfile)
        for period in periods do
            for ab in abba do
                    
                outflds = {"Urban_Code", "FacType", ab + "_VMT_" + period, ab + "_VHT_" + period, ab + "_SpeedCategory_" + period, ab + "_Speed_" + period}
                pth = SplitPath
                tmp = GetTempFileName("*.bin")
    
                numrecs = Line.CreateSet({SetName: "selection", Filter: ab + "_SpeedCategory_" + period + " <> null"})
                texp = Line.Export({FileName: tmp, FieldNames: outflds})
                texp.RenameField({FieldName: ab + "_VMT_" + period, NewName: "VMT"})
                texp.RenameField({FieldName: ab + "_VHT_" + period, NewName: "VHT"})
                texp.RenameField({FieldName: ab + "_SpeedCategory_" + period, NewName: "SpeedCategory"})
                texp.RenameField({FieldName: ab + "_Speed_" + period, NewName: "Speed"})
                texp = null
                tmpfiles = tmpfiles + {tmp}
                if period = "AM" and ab = "AB" then do
                    pth = SplitPath(tmp)
                    pth2 = SplitPath(mfile)
                    CopyFile(pth[1] + pth[2] + pth[3] + ".dcb", pth2[1] + pth2[2] + pth2[3] + ".dcb")
                end
            end
        end
        ConcatenateFiles(tmpfiles, mfile)
        mtab = CreateObject("Table", mfile)
        fields = {
        {FieldName: "SpeedVMT", Description: "Speed multiplied by VMT"}}
        mtab.AddFields({Fields: fields})
        mtab.SpeedVMT = mtab.Speed * mtab.VMT
        mtab = null
        rtypes = {"VMT", "VHT"}
        for rtype in rtypes do
            c = CreateObject("PivotGrid")
            flds = {"Urban_Code", "FacType", "VMT", "VHT", "SpeedCategory" }
            c.ConnectToGeoTable({FileName: mfile})
            c.AddField({FieldName: "Urban_Code", TargetArea: "RowArea"})
            c.AddField({FieldName: "FacType", TargetArea: "RowArea"})
            c.AddField({FieldName: "SpeedCategory", TargetArea: "ColumnArea"})
            c.AddField({FieldName: rtype, TargetArea: "DataArea"})
            c.WindowTitle = "PivotGrid " + "AQ " + rtype
            c.SetOptionsViewProperty("ShowRowGrandTotals", true)
            c.SetOptionsViewProperty("ShowColumnGrandTotals", true)
            c.SetOptionsViewProperty("ShowRowGrandTotalHeader", true)
            c.SetOptionsViewProperty("ShowColumnHeaders", true)
            c.SetOptionsViewProperty("ShowRowHeaders", true)
            c.Export({FileName:Args.("AQ" + rtype)})
//            ret = c.Run()
            c = null
        end
        c = CreateObject("PivotGrid")
        flds = {"Urban_Code", "FacType", "VMT", "SpeedVMT" }
        c.ConnectToGeoTable({FileName: mfile})
        c.AddField({FieldName: "Urban_Code", TargetArea: "RowArea"})
        c.AddField({FieldName: "FacType", TargetArea: "RowArea"})
        c.AddField({FieldName: "VMT", TargetArea: "DataArea"})
        c.AddField({FieldName: "SpeedVMT", TargetArea: "DataArea"})
        c.WindowTitle = "PivotGrid " + "AQ AvgSpeed"
        c.SetOptionsViewProperty("ShowRowGrandTotals", true)
        c.SetOptionsViewProperty("ShowColumnGrandTotals", true)
        c.SetOptionsViewProperty("ShowRowGrandTotalHeader", true)
        c.SetOptionsViewProperty("ShowColumnHeaders", true)
        c.SetOptionsViewProperty("ShowRowHeaders", true)
        c.Export({FileName:Args.AQSpeed})
//        ret = c.Run()
        c = null
 
    Return(ret_value)
endmacro 