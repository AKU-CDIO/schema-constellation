# -*- coding: utf-8 -*-
"""Generate data/phases.js = window.SCHEMA_PHASES.

Curated Phase 1-5 topic structure for the Data Topic Availability doc,
wired to the REAL Meditech schema tables in data/schema.js and to the
FCAP1A stored procedures in dev/fcap1a_utf8/.

Every table name is validated against data/schema.js; unknown names are
dropped with a warning so the emitted file always resolves.
"""
import io, json, os, re, glob

ROOT = r"C:\Users\derick.imbati\OneDrive - Aga Khan University\Documents\MasterPiece\MAYO\Cohort_Data_Sets\schema-constellation"
SQL_DIR = ROOT + r"\dev\fcap1a_utf8"
OUT = ROOT + r"\data\phases.js"

# ---- load schema.js tables ----
s = io.open(ROOT + r"\data\schema.js", encoding="utf-8").read()
data = json.loads(re.search(r"window\.SCHEMA_DATA\s*=\s*(\{.*\});", s, re.S).group(1))
TABLES = set(data["tables"].keys())

# ---- parse SP read tables (all table refs, minus derived/temp) ----
TEMP_PREFIX = ("Internal_", "External_", "ImmunAdr_", "All_", "Raw", "Final", "Dedup")
ref_pat = re.compile(r"(FROM|JOIN)\s+([A-Za-z0-9_\[\].]+)", re.I)


def sp_reads(sp_name):
    """Return sorted schema tables an SP reads directly (best-effort)."""
    f = os.path.join(SQL_DIR, "usp_Build_" + sp_name + ".sql")
    if not os.path.exists(f):
        return []
    t = io.open(f, encoding="utf-8-sig", errors="replace").read()
    seen = []
    for m in ref_pat.finditer(t):
        raw = m.group(2)
        tbl = raw.split(".")[-1].strip("[]")
        if not tbl or tbl in ("AdmVisits", "RegAcct_Main", "Cohort_Log"):
            continue
        if tbl.startswith("tbl_FCAP1A") or tbl.startswith("FCAP1A_"):
            continue
        if tbl.startswith(TEMP_PREFIX) or tbl.isupper() or tbl in (
                "NVARCHAR", "DATE", "DATETIME", "INT", "VARCHAR", "VERSION"):
            continue
        if tbl not in seen:
            seen.append(tbl)
    return [x for x in seen if x in TABLES]


INSERT_PAT = re.compile(r"INSERT\s+INTO\s+\[?dbo\]?\.?\[?(tbl_FCAP1A_\w+)\]?", re.I)


def sp_outputs(sp_name):
    """Actual output tables the SP writes, in order, matching schema.js names."""
    f = os.path.join(SQL_DIR, "usp_Build_" + sp_name + ".sql")
    if not os.path.exists(f):
        return []
    t = io.open(f, encoding="utf-8-sig", errors="replace").read()
    found = []
    for m in INSERT_PAT.finditer(t):
        n = m.group(1)
        if n in TABLES and n not in found:
            found.append(n)
    return found


def pick_output(sp_name):
    """Choose the primary output table: prefer the one that contains the SP name stem."""
    outs = sp_outputs(sp_name)
    if not outs:
        return "tbl_FCAP1A_" + sp_name
    stem = sp_name.replace("_Extended", "").lower()
    for o in outs:
        if stem in o.lower():
            return o
    return outs[0]


def keep(names):
    """Filter a list of table names down to those present in schema.js."""
    kept, dropped = [], []
    for n in names:
        (kept if n in TABLES else dropped).append(n)
    if dropped:
        print("   drop (not in schema.js):", ", ".join(dropped))
    return kept


# ---- curated phase structure ----
# topic: (id, name, desc, avail, note, sp or None, [tables])
PHASES = [
    ("Phase 1 · Core Clinical Data", "core", [
        ("adt", "ADT (Admit, Discharge, Transfer)",
         "Admit, discharge and transfer events for every visit; AKU records no intra-visit movements, so ADT = one admit event (AdmVisits.ServiceDateTime) + one discharge event.",
         "Yes", None, "FCAP1A_ADT_Extended",
         ["AdmVisits", "AdmittingData"]),
        ("allergies", "Allergies",
         "Documented allergies and adverse drug reactions: internally recorded allergies, external/allergy-main records and immunisation adverse reactions, normalised through the allergy dictionaries.",
         "Yes", None, "FCAP1A_Allergies_Extended",
         ["EmrPat_Allergies", "EmrPat_Allergies_AllrgComment", "EmrPat_ExtAllergies", "EmrPat_ExtAllergyMain", "EmrPat_ImmunAdrAllergies", "DMisAllergies"]),
        ("clinicalnotes", "Clinical Documents / Notes",
         "Free-text clinical documentation (notes and narrative) plus the results documents they draw from; clinical narrative and compiled-text views live on the same source tables.",
         "Yes", None, "FCAP1A_ClinicalNotes_Extended",
         ["EmrDocData_Main", "EmrDocData_Note", "EmrDocData_NoteText_Text", "ItsResult", "ItsResultCompiledText"]),
        ("diagnosis", "Diagnosis & Problem List",
         "Diagnoses at account level plus the active/office/pending problem list; both reconcile back to the patient hub and the diagnosis dictionary.",
         "Yes", None, "FCAP1A_Diagnoses_Extended",
         ["AbsAcct_Diagnoses", "EmrPat_Problems", "EmrPat_ProblemsMain", "MisPatProblem_Main"]),
        ("encounter", "Encounter Data",
         "The visit/encounter spine: visits, registration accounts, admit details and the providers attached to each encounter.",
         "Yes", None, "FCAP1A_Encounters_Extended",
         ["AdmVisits", "RegAcct_Main", "AdmittingData", "AdmConsultingProviders", "AdmProviders"]),
        ("vitals", "Flowsheet - Vitals",
         "Vital signs and patient data captured on the flowsheet, with growth-set charts for paediatrics.",
         "Yes", None, "FCAP1A_Flowsheets_Extended",
         ["AdmVitalSigns", "PhaPatData", "EmrGrowthSet_Main", "EmrGrowthChartAudit_Main", "EmrGrowthChartAudit_DataPoints"]),
        ("immunizations", "Immunizations",
         "Immunisation records: doses administered, multi-dose lots, comments and the vaccine / reason dictionaries.",
         "Yes", None, "FCAP1A_Immunizations_Extended",
         ["DPhaDrugData", "PhaRxImmunizationData", "PhaRxImmunizationDataMore", "PhaRxAdminImmunizations", "PhaRxAdminImmunMultiDoseLots", "PhaRxAdminImmunizationCmtsText", "MisImmReason_Main", "MisVaccine_Main"]),
        ("lab", "Lab Results",
         "Laboratory results: specimens, tests performed and result comments across the AKULivendb lab domain.",
         "Yes", None, "FCAP1A_Labs_Extended",
         ["LabSpecimens", "LabSpecimenTests", "DLabTest", "LabPatientResultCommentsText", "LabSpecimenCommentsText", "LabSpecimenResultCommentsText", "LabVisitIsolatedOrganisms"]),
        ("medications", "Medications",
         "Medication orders and administrations: prescriptions, MAR lines, scanned doses and the drug dictionaries.",
         "Yes", None, "FCAP1A_Medications_Extended",
         ["PhaRx", "PhaRxMedications", "PhaRxAdministrations", "PhaRxScannedMedPatientX", "DPhaDrugData", "DPhaGeneric"]),
        ("pathology", "Pathology Reports",
         "Anatomic pathology: specimens, final sign-outs and the addendum / correction / histology / findings text blocks.",
         "Yes", None, "FCAP1A_PathologyReports_Extended",
         ["PthSpecimens", "PthSpecimenFinalSignouts", "PthSpecimenCommentsText", "PthSpecimenAddendumText", "PthSpecimenCorrections", "PthSpecimenFindingsText", "PthSpecimenHistologyText"]),
        ("demographics", "Patient Demographics",
         "Patient master index and identity attributes: addresses, additional race/ethnicity and the demographic dictionaries (country, language, marital status, religion, education, race, ethnicity).",
         "Yes", None, "FCAP1A_Demographics_Extended",
         ["HimRec_Main", "HimRec_Data", "HimRec_Address", "HimRec_AdditionalRace", "HimRec_AdditionalEthnicity",
          "MisCntry_Main", "MisRace_Main", "MisEthnicity_Main", "MisLang_Main", "MisMaritalStatus_Main", "MisRelig_Main", "MisEduLvl_Main"]),
        ("ppi", "Patient Provided Info (PPI)",
         "Patient-entered data: contact preferences, employer, personal contacts, consent authorities and custom-data-query responses at patient and account level.",
         "Yes", None, "FCAP1A_PatientProvidedInfo_Extended",
         ["HimRec_CommPreferences", "HimRec_Employer", "HimRec_PersContAuth", "HimRec_PersContPhoneNumbers", "HimRec_PersonalContacts", "HimRec_VisitContactAuth",
          "HimRec_CustomDataQueries_Queries", "HimRec_CustomDataQueries_QueriesMult", "RegAcct_CustomDataQueries_Queries", "RegAcct_CustomDataQueries_QueriesMult"]),
        ("procedures", "Procedures",
         "Procedures and interventions performed on the account, plus the procedure-order and plan item records that carry them.",
         "Yes", None, "FCAP1A_Procedures_Extended",
         ["PcsAcct_Interventions", "PcsIntervention_Main", "PcsAcct_PlanItems", "PcsAcct_PlanText_PlanText"]),
        ("radiology", "Radiology Reports",
         "Radiology report text and images captured against the account; reports render from the image/result source tables.",
         "Yes", None, "FCAP1A_RadiologyReports_Extended",
         ["EmrAcctRep_Images"]),
        ("problemlist", "Problem List",
         "The longitudinal problem list (active, pending, office, health concerns) reconciled to the problem dictionary.",
         "Yes", "Covered in the diagnosis build; no dedicated SP yet.", None,
         ["EmrPat_Problems", "EmrPat_ProblemsMain", "EmrPat_PendingProblems", "EmrPat_OfficeProblems", "EmrPat_HealthConcerns", "MisPatProblem_Main"]),
    ]),
    ("Phase 2 · Operational & Ancillary", "ops", [
        ("appointments", "Appointments",
         "Scheduled appointments captured on the patient master.",
         "Yes", "Only HimRec_Appointments is in the curated source set; no SP yet.", None,
         ["HimRec_Appointments"]),
        ("providers", "Providers & Specialties",
         "Provider reference data: provider master, groups, types and the specialty / service dictionaries.",
         "Yes", None, "FCAP1A_Providers_Extended",
         ["MisSpec_Main", "MisSvc_Main", "DMisProvider", "DMisProviderGroup", "DMisProviderType"]),
        ("family", "Family Medical History",
         "Family members, family problem history and relationship/consanguinity, with the relationship dictionary.",
         "Yes", "Output exists as tbl_FCAP1A_FamilyMedicalHistory in the cohort layer; no dedicated build SP yet.", None,
         ["EmrPat_FamilyMembers", "EmrPat_FamilyMembers_DeceasedComment", "EmrPat_FamilyProblemMembers", "EmrPat_FamilyProblems", "MisRelat_Main"]),
        ("micro", "Microbiology",
         "Microbiology isolates and culture findings with the procedure and result-text sources.",
         "Yes", None, "FCAP1A_Labs_Microbiology_Extended",
         ["LabVisitIsolatedOrganisms", "MicSpecimenResultsText", "DMicProcs", "LabSpecimenTests"]),
        ("transfusion", "Transfusion (Blood Bank)",
         "Blood-bank specimen tests and the test dictionary - the source tables behind the BloodBank build.",
         "Yes", None, "FCAP1A_Labs_BloodBank_Extended",
         ["BbkSpecimenTests", "DBbkTests"]),
        ("treatmentplan", "Treatment Plan",
         "Care/treatment plans: plan headers and problem instances, oncologic plans and cycles, and the plan-activity / plan-text detail.",
         "Yes", None, "FCAP1A_TreatmentPlans_Extended",
         ["EmrClinDoc_Main", "EmrClinDoc_ProbInstPlans", "EmrClinDoc_ProbInstPlans_ProblemPlanText",
          "EmrPatPlan_Problems", "EmrPatPlan_Problems_ProblemLabel", "EmrPatPlan_Problems_ProblemMedsText", "EmrPatPlan_Problems_ProblemOrdersText", "EmrPatPlan_Problems_ProblemPlanText",
          "MisPatProblem_Main", "OncClinic_Main", "OncCycle_Main", "OncDx_Main", "OncIndication_Main", "OncPlanDict_Main", "OncPlanDict_Protocol_ProtocolMtext",
          "OncPlan_DateCycles", "OncPlan_Main", "OncPlan_Orders", "PcsAcctAct_PlanActivity", "PcsAcct_PlanItems", "PcsAcct_PlanText_PlanText", "PcsAcct_Plans", "PcsPlan_Main"]),
        ("medorders", "Medication Orders",
         "Medication orders in the pharmacy record and the order dictionary, independent of the MAR administrations.",
         "Yes", "Covered by the Medications build; no dedicated SP.", None,
         ["PhaRx", "PhaRxMedications", "DPhaDrugData", "OmOrd_Main", "OmOrd_Main2", "OmOrd_Main3", "OmOrdDict_Main"]),
        ("procorders", "Procedure Orders",
         "Procedure/order entry: order headers, categories, groups and the CPT dictionary.",
         "Yes", "Covered by the Orders build; no dedicated SP.", None,
         ["OmOrd_Main", "OmOrd_Main2", "OmOrd_Main3", "OmOrdDict_Main", "OmCat_Main", "OmGrp_Main", "MisCpt_Main"]),
        ("claims", "Claims Data",
         "Insurance claims and claim lines.",
         "No", "Claim tables are not in the curated Meditech source set.", None, []),
        ("ecgecho", "ECG & Echo",
         "Electrocardiogram and echocardiogram studies.",
         "No", "Cardiology study tables are external to the FCAP1A source set.", None, []),
        ("infusions", "Infusions",
         "Intravenous infusion records.",
         "No", "Infusion tables are not in the curated Meditech source set.", None, []),
        ("insurance", "Patient Insurance",
         "Payer plans and patient insurance eligibility.",
         "No", "Insurance/payer tables are not in the curated Meditech source set.", None, []),
        ("pft", "Pulmonary Function Test",
         "Pulmonary function testing studies.",
         "No", "PFT tables are not in the curated Meditech source set.", None, []),
        ("rhc", "RHC Measurements",
         "Right heart catheterisation measurements.",
         "No", "RHC tables are not in the curated Meditech source set.", None, []),
        ("social", "Social History",
         "Social and lifestyle history captured at intake.",
         "No", "Captured as part of Patient Provided Info; no dedicated table set.", None, []),
        ("surgery", "Surgical Cases",
         "Surgical case headers, events and schedules.",
         "No", "Surgical-case tables are not in the curated Meditech source set.", None, []),
    ]),
    ("Phase 3 · Imaging & Diagnostics", "imaging", [
        ("dicom", "DICOM Header",
         "Raw DICOM image metadata for every modality.",
         "No", "DICOM images live outside the Meditech relational DB (external modality).", None, []),
        ("ct", "CT",
         "Computed tomography imaging and reports.",
         "No", "Images are external; only report text is available via the radiology report source.", None, ["EmrAcctRep_Images"]),
        ("pet", "PET",
         "Positron emission tomography imaging and reports.",
         "No", "Images are external; only report text is available via the radiology report source.", None, ["EmrAcctRep_Images"]),
        ("mri", "MRI",
         "Magnetic resonance imaging and reports.",
         "No", "Images are external; only report text is available via the radiology report source.", None, ["EmrAcctRep_Images"]),
        ("echo", "Echocardiogram",
         "Echocardiogram studies and findings.",
         "No", "Echo study tables are external to the FCAP1A source set.", None, []),
        ("gi", "GI - Endoscopy",
         "Gastrointestinal endoscopy procedures.",
         "No", "Endoscopy tables are not in the curated Meditech source set.", None, []),
        ("us", "Ultrasound",
         "Ultrasound imaging and reports.",
         "No", "Images are external; only report text is available via the radiology report source.", None, ["EmrAcctRep_Images"]),
        ("cath", "Cardiology (Cath) Imaging",
         "Cardiac catheterisation imaging.",
         "No", "Cath-lab tables are not in the curated Meditech source set.", None, []),
        ("mammo", "Mammography",
         "Mammography imaging and reports.",
         "No", "Images are external; only report text is available via the radiology report source.", None, ["EmrAcctRep_Images"]),
    ]),
    ("Phase 4 · Specialty & Longitudinal", "specialty", [
        ("dpath", "Digital Pathology",
         "Whole-slide digital pathology images.",
         "No", "Digital pathology images are managed by an external pathology system.", None, []),
        ("ob", "OB / Delivery",
         "Obstetric deliveries and labour events.",
         "No", "OB tables are not in the curated Meditech source set.", None, []),
        ("derm", "Dermatology Imaging",
         "Dermatology clinical photography.",
         "No", "Images are external; only report text is available via the radiology report source.", None, ["EmrAcctRep_Images"]),
        ("eye", "Eye Imaging (Fundus, OCT)",
         "Fundus photography and optical coherence tomography.",
         "No", "Ophthalmology imaging tables are external to the FCAP1A source set.", None, []),
        ("vaccines", "Vaccines",
         "Vaccine administrations and dose detail, including the vaccine dictionary.",
         "Yes", "Covered by the Immunizations build; no dedicated SP.", None,
         ["EmrPat_Vaccines", "EmrPat_VaccinesDoses", "PhaRxImmunizationData", "MisVaccine_Main"]),
        ("otherreports", "Other Clinical Reports",
         "Patient-summary reports and generated results not tied to a single domain.",
         "Yes", "Report text is available via the summary/report source tables; no dedicated SP.", None,
         ["EmrAcctRep_Images", "EmrPatSum_Documents", "EmrPatSum_DocMrd", "EmrPatSum_Items", "EmrPatSum_GenResults", "EmrPatSum_LabResults"]),
    ]),
    ("Phase 5 · Extended & Future", "future", [
        ("registries", "Registries & Analytics",
         "Registry enrolments and longitudinal registry data (chronic conditions, last lab results).",
         "Yes", None, None,
         ["EmrPatRegistry_Main", "EmrPatRegistry_ChronicConds", "EmrPatRegistry_LastLabResults"]),
        ("orders", "Orders",
         "All order types: order headers, the order dictionary, categories, groups and the CPT dictionary.",
         "Yes", None, "FCAP1A_Orders",
         ["OmOrd_Main", "OmOrd_Main2", "OmOrd_Main3", "OmOrdDict_Main", "OmCat_Main", "OmGrp_Main", "MisCpt_Main", "HimRec_Main"]),
        ("xray", "X-Ray",
         "Radiography imaging and reports.",
         "No", "Images are external; covered by the Radiology Reports build for report text.", None, ["EmrAcctRep_Images"]),
        ("meddevice", "Medical Device",
         "Implanted and active medical devices.",
         "No", "Only the implant registry (EmrPat_ImplDev) is in the curated source set.", None, ["EmrPat_ImplDev"]),
        ("genomics", "Genomics",
         "Genomic sequencing and variant data.",
         "No", "Genomic data lives outside the Meditech relational DB.", None, []),
        ("biorepo", "Bio-repositories",
         "Biobank and sample repositories.",
         "No", "Biobank/sample repositories are external systems.", None, []),
        ("eeg", "Electrophysiology (EEG)",
         "EEG and neurophysiology studies.",
         "No", "EEG tables are not in the curated Meditech source set.", None, []),
        ("surgvideo", "Surgical Video",
         "Video capture from surgical suites.",
         "No", "Surgical video is captured by an external system (not in relational DB).", None, []),
    ]),
]

# ---- build output ----
phases_out = []
total_topics = 0
for pname, pid, topics in PHASES:
    t_out = []
    for tid, name, desc, avail, note, sp, tables in topics:
        kept = keep(tables)
        sp_out = None
        if sp:
            sp_out = {"name": sp, "out": pick_output(sp)}
        t_out.append({
            "id": tid, "name": name, "desc": desc,
            "avail": avail, "note": note, "sp": sp_out, "tables": kept,
        })
        total_topics += 1
    phases_out.append({"id": pid, "name": pname, "topics": t_out})

out = {"phases": phases_out}
with io.open(OUT, "w", encoding="utf-8", newline="\n") as f:
    f.write("window.SCHEMA_PHASES = ")
    f.write(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
    f.write(";\n")

print("wrote", OUT)
print("phases:", len(phases_out), "| topics:", total_topics)
for p in phases_out:
    spd = sum(1 for t in p["topics"] if t["sp"])
    print("  %-42s topics=%2d  sp=%2d  avail=%d" % (p["name"], len(p["topics"]), spd, sum(1 for t in p["topics"] if t["avail"] == "Yes")))
