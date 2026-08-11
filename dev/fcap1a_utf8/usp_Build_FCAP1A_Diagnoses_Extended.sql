/* Author: test */
﻿USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Diagnoses_Extended]    Script Date: 7/13/2026 12:59:28 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* 
   Stored Procedure: usp_Build_FCAP1A_Diagnoses_Extended
   
   Purpose:
     • Rebuilds the FCAP 1A Diagnoses_Extended dataset for the Extended 10% cohort
     • Sources visit-level diagnoses from AbsAcct_Diagnoses
     • Links diagnoses to the FCAP Extended 10% cohort via AdmVisits
     • Uses RowUpdateDateTime as the master diagnosis timestamp
     • Recreates dbo.tbl_FCAP1A_Diagnoses_Extended on each run
     • Logs execution details to dbo.FCAP1A_Cohort_Log

   Author      : Allan Zablon
   Date        : 2026-02-19 (Enhanced FCAP Phase 1 Extended version)
   Revised     : 2026-07-13 (matched with iserc request)
   Notes       :
     - ICD-10 only environment
     - Encounter context (IP/OP, Facility, etc.) is handled in ADT,
       not duplicated here
     - This fact is diagnosis-centric and federated-analytics friendly
    */
ALTER     PROCEDURE [dbo].[usp_Build_FCAP1A_Diagnoses_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart        DATETIME = SYSDATETIME(),
        @RunEnd          DATETIME,
        @DurationSeconds INT,
        @RecordCount     INT = 0,
        @TotalEligible   INT = NULL,
        @WindowStart     DATE = '2022-11-05',
        @WindowEnd       DATE = '2026-06-14',
        @WindowEndNextDay DATE = DATEADD(DAY, 1, '2026-06-14');

    
    -- 1. Ensure log table exists (shared across FCAP topics)
    
    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log (
            LogID         INT IDENTITY(1,1) PRIMARY KEY,
            RunStart      DATETIME       NOT NULL,
            RunEnd        DATETIME           NULL,
            DurationSeconds INT              NULL,
            RunStatus     VARCHAR(20)    NOT NULL,
            DataTopic     NVARCHAR(100) NOT NULL,
            WindowStart   DATE              NULL,
            WindowEnd     DATE              NULL,
            TotalEligible INT               NULL,
            RecordCount   INT               NULL,
            ProcessedBy   NVARCHAR(100)     NOT NULL DEFAULT SYSTEM_USER,
            ErrorMessage  NVARCHAR(4000)    NULL,
            Remarks       NVARCHAR(4000)    NULL
        );
    END;

    
    -- 2. Recreate output table dbo.tbl_FCAP1A_Diagnoses_Extended
    --    Grain: one row per diagnosis instance per visit
    
    IF OBJECT_ID('dbo.tbl_FCAP1A_Diagnoses_Extended','U') IS NOT NULL
    BEGIN
        DROP TABLE dbo.tbl_FCAP1A_Diagnoses_Extended;
    END;

    CREATE TABLE dbo.tbl_FCAP1A_Diagnoses_Extended
    (
        -- Surrogate key in FCAP staging
        DiagnosisRowID INT IDENTITY(1,1) PRIMARY KEY,

        -- Keys / linkage
        PatientID       NVARCHAR(255) NOT NULL,
        VisitID         NVARCHAR(255) NOT NULL,
        DiagnosisUrnID  INT           NULL,  -- Natural diagnosis row identifier
        SortOrder       INT           NULL,  -- Diagnosis sequence within visit

        -- Master diagnosis timestamp (per FCAP standard)
        RowUpdateDateTime DATETIME    NULL,

        -- Core diagnosis semantics
        DiagnosisCode_MisDxID                      NVARCHAR(15)   NULL,
        DiagnosisName                              NVARCHAR(375)  NULL,
        DiagnosisType_MisDxTypeID                  NVARCHAR(15)   NULL,
        DiagnosisPrefix_MisDxPrefixID              NVARCHAR(2)    NULL,
        DiagnosisPresentOnAdmission_MisPresOnAdmID NVARCHAR(2)    NULL,
        DiagnosisComplicationComorbidity           NVARCHAR(3)    NULL,
        DiagnosisHospitalAcquiredCondition         NVARCHAR(3)    NULL,
        DiagnosisComplicationComorbidityOvAffectDrg NVARCHAR(3)   NULL,

        -- Grouper / APG / severity
        DiagnosisGrouperVersionField_MisGrouperVersionID NVARCHAR(15)  NULL,
        DiagnosisApgCode_MisApgID                       NVARCHAR(6)   NULL,
        DiagnosisApgType                                NVARCHAR(5)   NULL,
        DiagnosisApgCategory                            NVARCHAR(14)  NULL,
        DiagnosisApgPackaging                           NVARCHAR(14)  NULL,
        DiagnosisPpc                                    NVARCHAR(3)   NULL,

        -- Supplemental diagnosis attributes
        DiagnosisAlternateFlag   NVARCHAR(3)     NULL,
        DiagnosisCaType          NVARCHAR(5)     NULL,
        DiagnosisCluster         NVARCHAR(2)     NULL,
        DiagnosisEffectiveDateID DATETIME        NULL,
        DiagnosisRecurDateTime   DATETIME        NULL,
        DiagnosisFromTransferService NVARCHAR(1250) NULL,
        DiagnosisGemsComplete    NVARCHAR(3)     NULL,
        DiagnosisNumberCaOutcome INT             NULL,
        DiagnosisRolloverAccount NVARCHAR(18)    NULL,
        DiagnosisSource          NVARCHAR(45)    NULL,
        SourceID                 NVARCHAR(3)     NULL,

        -- ETL metadata
        ExtractedFrom NVARCHAR(200)              NULL,
        ExtractedOn   DATETIME       NOT NULL DEFAULT (SYSDATETIME())
    );

    BEGIN TRY
        
        -- 3. Determine TotalEligible patients in the FCAP Extended 10% cohort
        --    (for logging / QC only)
        
        SELECT @TotalEligible = COUNT(*)
        FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        
        -- 4. Insert diagnosis records (cohort + date window)
        --
        --    - Cohort anchor: dbo.tbl_FCAP1A_Cohort10_Extended
        --    - Patient linkage: AdmVisits.PatientID
        --    - Diagnosis source: AbsAcct_Diagnoses
        --    - Time window: AbsAcct_Diagnoses.RowUpdateDateTime
        --    - Collation alignment: SQL_Latin1_General_CP1_CI_AS
        --    - DISTINCT: protects against accidental join expansion
        
        INSERT INTO dbo.tbl_FCAP1A_Diagnoses_Extended
        (
            PatientID,
            VisitID,
            DiagnosisUrnID,
            SortOrder,
            RowUpdateDateTime,

            DiagnosisCode_MisDxID,
            DiagnosisName,
            DiagnosisType_MisDxTypeID,
            DiagnosisPrefix_MisDxPrefixID,
            DiagnosisPresentOnAdmission_MisPresOnAdmID,
            DiagnosisComplicationComorbidity,
            DiagnosisHospitalAcquiredCondition,
            DiagnosisComplicationComorbidityOvAffectDrg,

            DiagnosisGrouperVersionField_MisGrouperVersionID,
            DiagnosisApgCode_MisApgID,
            DiagnosisApgType,
            DiagnosisApgCategory,
            DiagnosisApgPackaging,
            DiagnosisPpc,

            DiagnosisAlternateFlag,
            DiagnosisCaType,
            DiagnosisCluster,
            DiagnosisEffectiveDateID,
            DiagnosisRecurDateTime,
            DiagnosisFromTransferService,
            DiagnosisGemsComplete,
            DiagnosisNumberCaOutcome,
            DiagnosisRolloverAccount,
            DiagnosisSource,
            SourceID,

            ExtractedFrom
        )
        SELECT DISTINCT
            v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS AS PatientID,
            v.VisitID   COLLATE SQL_Latin1_General_CP1_CI_AS AS VisitID,
            d.DiagnosisUrnID,
            d.SortOrder,
            d.RowUpdateDateTime,

            d.DiagnosisCode_MisDxID,
            d.DiagnosisName,
            d.DiagnosisType_MisDxTypeID,
            d.DiagnosisPrefix_MisDxPrefixID,
            d.DiagnosisPresentOnAdmission_MisPresOnAdmID,
            d.DiagnosisComplicationComorbidity,
            d.DiagnosisHospitalAcquiredCondition,
            d.DiagnosisComplicationComorbidityOvAffectDrg,

            d.DiagnosisGrouperVersionField_MisGrouperVersionID,
            d.DiagnosisApgCode_MisApgID,
            d.DiagnosisApgType,
            d.DiagnosisApgCategory,
            d.DiagnosisApgPackaging,
            d.DiagnosisPpc,

            d.DiagnosisAlternateFlag,
            d.DiagnosisCaType,
            d.DiagnosisCluster,
            d.DiagnosisEffectiveDateID,
            d.DiagnosisRecurDateTime,
            d.DiagnosisFromTransferService,
            d.DiagnosisGemsComplete,
            d.DiagnosisNumberCaOutcome,
            d.DiagnosisRolloverAccount,
            d.DiagnosisSource,
            d.SourceID,

            N'AbsAcct_Diagnoses (AKULiveATdb)' AS ExtractedFrom
        FROM dbo.tbl_FCAP1A_Cohort10_Extended AS c
        INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits AS v
            ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
               = v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].dbo.AbsAcct_Diagnoses AS d
            ON v.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
               = d.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
        WHERE d.RowUpdateDateTime >= @WindowStart
          AND d.RowUpdateDateTime < @WindowEndNextDay;

        
        -- 5. Post-insert counts and timing
        
        SELECT @RecordCount = COUNT(*) FROM dbo.tbl_FCAP1A_Diagnoses_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        
        -- 6. Log success to FCAP1A_Cohort_Log
        
        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ProcessedBy,
            Remarks
        )
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            N'Diagnoses_Extended',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            @RecordCount,
            SYSTEM_USER,
            N'Diagnoses_Extended rebuild completed successfully.'
        );

        PRINT 'Diagnoses_Extended rebuild completed successfully.';
        PRINT 'Rows inserted: '       + CAST(@RecordCount AS VARCHAR(20));
        PRINT 'Total eligible patients (cohort): ' + ISNULL(CAST(@TotalEligible AS VARCHAR(20)), 'NULL');
        PRINT 'Duration (seconds): ' + CAST(@DurationSeconds AS VARCHAR(20));
    END TRY
    BEGIN CATCH
        
        -- 7. Log failure, then rethrow for upstream handling
        
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES
        (
            @RunStart,
            SYSDATETIME(),
            NULL,
            'FAILED',
            N'Diagnoses_Extended',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            NULL,
            SYSTEM_USER,
            @ErrMsg,
            N'Error during Diagnoses_Extended rebuild.'
        );

        THROW;
    END CATCH;
END;