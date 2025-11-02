macro "VisitorModel" (Args, Result)

    RunMacro("VisitorPopSynth", Args)
    RunMacro("VisitorTripGen", Args)
    RunMacro("VisitorChoices", Args)
    RunMacro("VisitorNLB", Args)
    RunMacro("VisitorTOD", Args)
    Return(1)
endmacro

macro "VisitorPopSynth" (Args)

    // Add fields to SED file for occupied hotel rooms and dummy district   
    SEDfile = Args.SE
    SED = CreateObject("Table", {FileName: SEDfile})
    fields = {
        {FieldName: "OccHotelRooms", Type: "Real", Description: "Occupied Hotel Rooms"},
        {FieldName: "Dummy", Type: "Integer", Description: "Dummy District for Visitor Synth Pop"}
        }
    SED.AddFields({Fields: fields})
    Dummy = if SED.TAZ > 0 then 1 else 1
    SED.SetDataVectors({FieldData: {{"Dummy", Dummy}}})

    // Apply Occupancy Rates
    TAZfile = Args.TAZs
    TAZ = CreateObject("Table", {FileName: TAZfile})
    TAZSED = TAZ.Join({Table: SED, LeftFields: {"TAZ"}, RightFields: {"TAZ"} })
    OccHotelRooms = if TAZSED.VisitDist = 2 then Args.OccRateDwntwn * TAZSED.HotelRms else Args.OccRateOther * TAZSED.HotelRms  
    TAZSED.SetDataVectors({FieldData: {{"OccHotelRooms", OccHotelRooms}}})
    TAZSED = null

    // Synthesize Visitor Population
    hh_file = Args.VisitorPartySeed
    pp_file = Args.VisitorPersonSeed
    
    o = CreateObject("PopulationSynthesis")
    
    o.HouseholdFile({ FileName: hh_file , Filter: "", ID: "sampno", 
        MatchingID: "Dummy", WeightField: "vis_wght"})

    o.PersonFile({ FileName: pp_file , Filter: "", ID: "PID", HHID: "sampno"})

    o.MarginalFile({ FileName: SEDfile, Filter:"", ID: "TAZ",   MatchingID: "Dummy"}) 

    HHDimSynmargData1 = {{ Name: "OccHotelRooms" , Value: {1, 99999}}}
    o.AddHHMarginal({ Field: "Dummy", Value: HHDimSynmargData1  , NewFieldName: "Dummy"})

    outputFolder = Args.[Output Folder] + "\\visitors\\"
    o.OutputHouseholdsFile   = outputFolder + "VisitorParties.bin"
    o.OutputPersonsFile      = outputFolder + "VisitorPersons.bin"

    o.ReportExtraHouseholdField("agever", "AgeCat")
    o.ReportExtraHouseholdField("vpurp2", "Purpose")
    o.ReportExtraHouseholdField("hhsiz", "PartySize")
    o.ReportExtraHouseholdField("solo", "Solo")
    o.ReportExtraHouseholdField("kids", "Kids")
    o.ReportExtraHouseholdField("incmed", "Income")

    o.ReportExtraPersonsField("age", "age")
    o.ReportExtraPersonsField("sex", "sex")

    ret_value = o.Run()

endMacro

macro "VisitorTripGen" (Args)
    outputFolder = Args.[Output Folder] + "\\visitors\\"
    hhfile = outputFolder + "VisitorParties.bin"
    perfile = outputFolder + "VisitorPersons.bin"
    SEDfile = Args.SE

    // Add district fields
    HH = CreateObject("Table", {FileName: hhfile})
    fields = {
        {FieldName: "Downtown", Type: "Integer", Description: "In Downtown"}
        }
    HH.AddFields({Fields: fields})
    TAZfile = Args.TAZs
    TAZ = CreateObject("Table", {FileName: TAZfile})
    HHTAZ = HH.Join({Table: TAZ, LeftFields: {"ZoneID"}, RightFields: {"TAZ"} })
    HHTAZ.Downtown = if HHTAZ.VisitDist = 2 then 1 else 0
    HHTAZ = null

    // Get rates
    ratesfile = Args.VisitorProdRates
    ratesvw = CreateObject("Table", {FileName: ratesfile})
    v_type = ratesvw.trip_type
    v_query = ratesvw.rule
    v_rate = ratesvw.rate
    
    // Add fields and join files
    P = CreateObject("Table", {FileName: perfile})    
    SED = CreateObject("Table", {FileName: SEDfile})
    v_unique_types = SortVector(v_type, {Unique: true})
    for field in v_unique_types do
        P.AddFields({Fields: {{FieldName: field, Type: "Real", Description: "Visitor " + field + " Productions"}}})
        SED.AddFields({Fields: {{FieldName: field+"P", Type: "Real", Description: "Visitor " + field + " Productions"}}})
    end
    PHH = P.Join({Table: HH, LeftFields: {"HouseholdID"}, RightFields: {"HouseholdID"} })
    
    // Loop over queries/rates
    view = PHH.GetView()
    SetView(view)
    for i = 1 to v_type.length do
        type = v_type[i]
        query = v_query[i]
        rate = v_rate[i]

        if i = 1 or type <> v_type[i - 1] then expression = "if (" + query + ") then " + String(rate) + "*PartySize"
        else expression = expression + " else if (" + query + ") then " + String(rate) + "*PartySize"
        
        if i = v_type.length or type <> v_type[i + 1] then do
            e_field = CreateExpression(view, "expr", expression, {Type: "Real"})
            data.(type) = GetDataVector(view + "|", e_field, )
            e_spec = GetFieldFullSpec(view, e_field)
            DestroyExpression(e_spec)
        end
    end
    PHH.SetDataVectors({FieldData: data})

    // Aggregate Individual Visitor Trips to Lodging Zones
    SEDPHH = SED.Join({Table: PHH, LeftFields: {"TAZ"}, RightFields: {"ZoneID"}, Options: {{"A", } }})
    for field in v_unique_types do
        SEDPHH.(field+"P") = SEDPHH.(field) 
    end
    SEDPHH = null
    PHH = null
endMacro

macro "VisitorChoices" (Args)

    // Prepare skim variables for choices
    askim = CreateObject("Matrix", Args.AvgRoadwaySkimMDhov)
    tskim = CreateObject("Matrix", Args.TransitSkimMDall)

    askim.AddCores({"LnTime"})
    askim.AddCores({"TaxiFare"})
    tskim.AddCores({"WTT"})

    askim.LnTime := log(askim.CongTime)
    askim.TaxiFare := 4.00 + 0.70*askim.[Length (Skim)] + 0.25*askim.CongTime      // UPDATE: using TRM TNC fare formula for now
    tskim.WTT := tskim.[In-Vehicle Time] + 1.5*(tskim.[Initial Wait Time] + tskim.[Transfer Wait Time] + tskim.[Transfer Penalty Time] + tskim.[Transfer Walk Time] + tskim.[Access Walk Time] + tskim.[Egress Walk Time] + tskim.[Dwelling Time])
    
    // Get and loop over LB trip purposes 
    mcpath = Args.[Master Folder] + "\\visitors\\mc\\"
    voutpath = Args.[Output Folder] + "\\visitors\\"
    mcfiles = GetDirectoryInfo(mcpath + "*.mdl", "File")
    for i = 1 to mcfiles.length do
        // Calculate MC probabilities and logsums
        o = CreateObject("Choice.Mode")     
        model_file = mcpath + mcfiles[i][1]
        purp = left(mcfiles[i][1], len(mcfiles[i][1]) - 4)
        o.ModelFile = model_file     
        o.OpenMatrixSource({SourceName: "Matrix1", FileName: Args.AvgRoadwaySkimMDhov})     
        o.OpenMatrixSource({SourceName: "Matrix2", FileName: Args.TransitSkimMDall})     
        o.OpenMatrixSource({SourceName: "Matrix3", FileName: Args.WalkSkim})     
        o.DropModeIfMissing = true     
        o.UtilityScaling = "By Theta Product"     
        o.AddMatrixOutput( "*", { Probability: voutpath + purp + "_Prob.mtx",     Logsum: voutpath + purp + "_Logs.mtx"})     
        ret_value = o.Run()
    end

    // Calculate Size Variables / Attractions
    // Get rates
    ratesfile = Args.VisitorAttrRates
    ratesvw = CreateObject("Table", {FileName: ratesfile})
    v_type = ratesvw.trip_type
    v_coef = ratesvw.rate
    v_fact = ratesvw.factor
    
    // Add fields 
    SED = CreateObject("Table", {FileName: Args.SE})
    v_unique_types = SortVector(v_type, {Unique: true})
    for field in v_unique_types do
        SED.AddFields({Fields: {{FieldName: field+"A", Type: "Real", Description: "Visitor " + field + " Attractions"},
                                {FieldName: field+"S", Type: "Real", Description: "Visitor " + field + " Size Variable"},
                                {FieldName: field+"Av", Type: "Real", Description: "Visitor " + field + " Availability"}}})
    end
    
    // Loop over rates
    view = SED.GetView()
    SetView(view)
    for i = 1 to v_type.length do
        type = v_type[i]
        factor = v_fact[i]
        rate = v_coef[i]

        if i = 1 or type <> v_type[i - 1] then expression = String(rate) + " * " + factor
        else expression = expression + " + " + String(rate) + " * " + factor
        
        if i = v_type.length or type <> v_type[i + 1] then do
            e_field = CreateExpression(view, "expr", expression, {Type: "Real"})
            data.(type + "A") = GetDataVector(view + "|", e_field, )
            data.(type + "S") = log(data.(type + "A"))
            data.(type + "Av") = if data.(type + "A") > 0 then 1 else null 
            e_spec = GetFieldFullSpec(view, e_field)
            DestroyExpression(e_spec)
        end
    end
    SED.SetDataVectors({FieldData: data})

    // Apply LB Destination Choice models
    dcpath = Args.[Master Folder] + "\\visitors\\dc\\"
    dcfiles = GetDirectoryInfo(dcpath + "*.dcm", "File")
    for i = 1 to dcfiles.length do
        o = CreateObject("Choice.Destination")     
        model_file = dcpath + dcfiles[i][1]
        purp = left(dcfiles[i][1], len(dcfiles[i][1]) - 4)
        o.ModelFile = model_file     
        o.OpenTableSource({SourceName: "Data1", FileName: Args.SE})     
        o.OpenTableSource({SourceName: "Data2", FileName: Args.NHBGenerationAccessibilities})     
        o.OpenMatrixSource({SourceName: "Matrix1", FileName: Args.AvgRoadwaySkimMDhov})       
        o.OpenMatrixSource({SourceName: "Matrix2", FileName: voutpath + purp + "_Logs.mtx"})   
        o.TotalsMatrix(voutpath + purp + "_PA.mtx")   
        ret_value = o.Run()
    end

    // Apply MC probabilities & write LB trips by mode to TAZ
    for i = 1 to dcfiles.length do
        purp = left(dcfiles[i][1], len(dcfiles[i][1]) - 4)
        pa = CreateObject("Matrix", voutpath + purp + "_PA.mtx")
        prob = CreateObject("Matrix", voutpath + purp + "_Prob.mtx")
        modes = prob.GetCoreNames()
        for j = 1 to modes.length do 
            pa.AddCores({modes[j]})
            pa.(modes[j]) := pa.Total * prob.(modes[j])
            SED.AddFields({Fields: {{FieldName: purp+"_"+modes[j], Type: "Real", Description: "Visitor LB " + purp+"_"+modes[j] + " Trips"}}})
            SED.(purp+"_"+modes[j]) = pa.GetVector({Core: modes[j], Marginal: "Column Sum"})
        end
    end
endMacro

macro "VisitorNLB" (Args)

    // Get rates
    ratesfile = Args.VisitorNLBRates
    ratesvw = CreateObject("Table", {FileName: ratesfile})
    v_type = ratesvw.trip_type
    v_coef = ratesvw.rate
    v_fact = ratesvw.factor
    
    // Add fields 
    SED = CreateObject("Table", {FileName: Args.SE})
    v_unique_types = SortVector(v_type, {Unique: true})
    for field in v_unique_types do
        SED.AddFields({Fields: {{FieldName: field, Type: "Real", Description: "Visitor BLB "+ field + " Productions"}}})
    end
    
    // Loop over rates
    view = SED.GetView()
    SetView(view)
    for i = 1 to v_type.length do
        type = v_type[i]
        factor = v_fact[i]
        rate = v_coef[i]

        if i = 1 or type <> v_type[i - 1] then expression = String(rate) + " * " + factor
        else expression = expression + " + " + String(rate) + " * " + factor
        
        if i = v_type.length or type <> v_type[i + 1] then do
            e_field = CreateExpression(view, "expr", expression, {Type: "Real"})
            data.(type) = GetDataVector(view + "|", e_field, )
            e_spec = GetFieldFullSpec(view, e_field)
            DestroyExpression(e_spec)
        end
    end
    SED.SetDataVectors({FieldData: data})

    // Apply accessibility boosting
    ACC = CreateObject("Table", {FileName: Args.NHBGenerationAccessibilities})
    ratesfile = Args.VisitorNLBboost
    ratesvw = CreateObject("Table", {FileName: ratesfile})
    v_type = ratesvw.trip_type
    v_coef = ratesvw.rate
    v_fact = ratesvw.factor
    view = SED.GetView()
    SetView(view)
    for i = 1 to v_type.length do
        type = v_type[i]
        factor = v_fact[i]
        rate = v_coef[i]

        if i = 1 or type <> v_type[i - 1] then alpha = rate
        else do
            gamma = rate
            access = factor
        end
        
        if i = v_type.length or type <> v_type[i + 1] then do
            SED.(type) = alpha*pow(ACC.(access),gamma)*SED.(type)
        end
    end

    // NLB Doubly-constrained gravity 
    obj = CreateObject("Distribution.Gravity")        
    obj.ResetPurposes()         
    obj.DataSource = {TableName: Args.SE}   
    betasvw = CreateObject("Table", {FileName: Args.VisitorNLBgrav})
    types = betasvw.trip_type
    betas = betasvw.beta
    skims = betasvw.Skim
    for i = 1 to types.length do
        if skims[i] = "Auto" then ImpMat = {MatrixFile: Args.AvgRoadwaySkimMDhov, Matrix: "CongTime", RowIndex: "Origin", ColIndex: "Destination"}
        if skims[i] = "Transit" then do
            ImpMat = {MatrixFile: Args.TransitSkimMDall, Matrix: "Total Time", RowIndex: "RCIndex", ColIndex: "RCIndex"}
            // Eliminate transit P's/A's where there is no transit service
            SED.(types[i]) = if ACC.access_transit = 0 then 0 else SED.(types[i])
        end
        if skims[i] = "Walk" then ImpMat = {MatrixFile: Args.WalkSkim, Matrix: "WalkTime", RowIndex: "Origin", ColIndex: "Destination"}    
        obj.AddPurpose({Name: types[i], Production: types[i], Attraction: types[i],                 
                ConstraintType: "Doubly",                
                ImpedanceMatrix: ImpMat, Inverse: betas[i]})        
    end
    obj.OutputMatrix({MatrixFile: Args.[Output Folder] + "\\visitors\\NLB.mtx", MatrixLabel : "Gravity",             
            Compression: true, ColumnMajor: false})         
    ret_value = obj.Run()         
endMacro    

macro "VisitorTOD" (Args)

    vpath = Args.[Master Folder] + "\\visitors\\"
    voutpath = Args.[Output Folder] + "\\visitors\\"
    files = GetDirectoryInfo(vpath + "*tod.bin", "File")
    for i = 1 to files.length do
        purp = left(files[i][1], len(files[i][1]) - 7)
        if purp = "NLB" then goto skip
        o = CreateObject("Distribution.PA2OD")     
        o.Matrix(voutpath + purp + "_PA.mtx")     
        pa = CreateObject("Matrix", voutpath + purp + "_PA.mtx")
        o.LoadRateTable(vpath + files[i][1])     
        o.TimePeriod(0, 4)     
        cores = pa.GetCoreNames()
        for j = 1 to cores.length do 
            occ = if cores[j] = "HOV" then 2.7 else if cores[j] = "TNC" then 1.9375 else 1
            o.AddPurpose({Name: cores[j], DepartureField: "PA",         
                ReturnField: "AP", Occupancy: occ}) 
        end   
        o.OutputMatrix(voutpath + purp + "_OD.mtx")     
        o.ReportByHour = true     
        ret_value = o.Run() 
        skip:    
    end 

    o = CreateObject("Distribution.PA2OD")     
    o.Matrix(voutpath + "NLB.mtx")     
    pa = CreateObject("Matrix", voutpath + "NLB.mtx")
    o.LoadRateTable(vpath + "NLBtod.bin")     
    o.TimePeriod(0, 4)     
    cores = pa.GetCoreNames()
    for i = 1 to cores.length do 
        occ = if cores[i] contains "HOV" then 2.7 else if cores[i] contains "TNC" then 1.9375 else 1
        field = left(cores[i],len(cores[i])-3)
        o.AddPurpose({Name: cores[i], DepartureField: field,         
            ReturnField: field, Occupancy: occ}) 
    end   
    o.OutputMatrix(voutpath + "NLB_OD.mtx")     
    o.ReportByHour = true     
    ret_value = o.Run()     

    periods = {"AM","MD","PM","NT"}
    per = {"(0-1)", "(1-2)", "(2-3)", "(3-4)"}
    odfiles = GetDirectoryInfo(voutpath + "*OD.mtx", "File")
    for i = 1 to periods.length do 
        CopyFile(voutpath + "BLB_PA.mtx",voutpath + "VIS_" + periods[i] + ".mtx")
        ODP = CreateObject("Matrix", voutpath + "VIS_" + periods[i] + ".mtx")
        modes = ODP.GetCoreNames()
        for j = 1 to modes.length do
            ODP.(modes[j]) := if ODP.(modes[j]) > 0 then 0 else 0
            for k = 1 to odfiles.length do
                OD = CreateObject("Matrix", voutpath + odfiles[k][1])
                cores = OD.GetCoreNames()
                for l = 1 to cores.length do
                    coremode = left(right(cores[l],9),3)
                    if coremode = modes[j] and cores[l] contains per[i] then ODP.(modes[j]) := Nz(ODP.(modes[j])) + Nz(OD.(cores[l]))
                end
            end
        end
    end
endMacro    