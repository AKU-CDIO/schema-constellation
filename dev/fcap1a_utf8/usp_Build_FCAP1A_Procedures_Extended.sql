/* Author: test */
﻿USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Procedures_Extended]    Script Date: 7/13/2026 1:30:28 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
Procedure Name : usp_Build_FCAP1A_Procedures_Extended
Author         : Allan Zablon
Environment    : FCAP 1A Extended
Build Type     : Full Rebuild
Cohort         : tbl_FCAP1A_Cohort10_Extended
Window         : 2022-11-05 through 2026-01-31 (inclusive)
Window Update  : 2022-11-05 through 2026-06-14 (inclusive)

Description:
Builds the Extended FCAP Procedures dataset scoped to the defined clinical window.
One row per InterventionUrnID.
*/

ALTER PROCEDURE [dbo].[usp_Build_FCAP1A_Procedures_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunStart DATETIME = SYSDATETIME();
    DECLARE @RunEnd DATETIME;
    DECLARE @DurationSeconds INT;
    DECLARE @RecordCount INT = 0;
    DECLARE @WindowStart DATE = '2022-11-05';
    DECLARE @WindowEnd   DATE = '2026-06-14';
    DECLARE @WindowEndNextDay DATE = DATEADD(DAY, 1, @WindowEnd);

    BEGIN TRY

        IF OBJECT_ID('dbo.tbl_FCAP1A_Procedures_Extended','U') IS NOT NULL
            DROP TABLE dbo.tbl_FCAP1A_Procedures_Extended;

        CREATE TABLE dbo.tbl_FCAP1A_Procedures_Extended
        (
            ProcedureRowID              INT IDENTITY(1,1) PRIMARY KEY,
            PatientID                   NVARCHAR(255) NOT NULL,
            SourceID                    NVARCHAR(50)  NOT NULL,
            VisitID                     NVARCHAR(255) NOT NULL,
            InterventionUrnID           NVARCHAR(50)  NOT NULL,
            ProcedureCode               NVARCHAR(50)  NOT NULL,
            ProcedureName               NVARCHAR(255) NULL,
            ProcedureMnemonic           NVARCHAR(255) NULL,
            NomenclatureMapID           NVARCHAR(255) NULL,
            ProcedureStatus             NVARCHAR(50)  NOT NULL,
            ProcedureInitializeDateTime DATETIME NULL,
            ProcedureStartDateTime      DATETIME NULL,
            ProcedureCompleteDateTime   DATETIME NULL,
            RowUpdateDateTime           DATETIME      NOT NULL,
            ExtractedOn                 DATETIME      NOT NULL DEFAULT SYSDATETIME()
        );

        INSERT INTO dbo.tbl_FCAP1A_Procedures_Extended
        (
            PatientID,
            SourceID,
            VisitID,
            InterventionUrnID,
            ProcedureCode,
            ProcedureName,
            ProcedureMnemonic,
            NomenclatureMapID,
            ProcedureStatus,
            ProcedureInitializeDateTime,
            ProcedureStartDateTime,
            ProcedureCompleteDateTime,
            RowUpdateDateTime
        )
        SELECT
            r.PatientID,
            i.SourceID,
            i.VisitID,
            i.InterventionUrnID,
            i.Intervention_PcsInterventionID,
            d.Name,
            d.Mnemonic,
            d.NomenclatureMap_MisNomenclatureMapID,
            i.InterventionStatus,
            i.InterventionInitializeDateTime,
            i.InterventionStartDateTime,
            i.InterventionCompleteDateTime,
            i.RowUpdateDateTime
        FROM [NBIDRSRV2].[AKULiveATdb].dbo.PcsAcct_Interventions i
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].dbo.RegAcct_Main r
            ON r.SourceID = i.SourceID
            AND r.VisitID  = i.VisitID
        INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c
            ON r.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
             = c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].dbo.PcsIntervention_Main d
            ON d.SourceID = i.SourceID
            AND d.PcsInterventionID = i.Intervention_PcsInterventionID
        WHERE
            (
                i.InterventionStartDateTime >= @WindowStart
                AND i.InterventionStartDateTime < @WindowEndNextDay
            )
            OR
            (
                i.InterventionStartDateTime IS NULL
                AND i.InterventionCompleteDateTime >= @WindowStart
                AND i.InterventionCompleteDateTime < @WindowEndNextDay
            )
            OR
            (
                i.InterventionStartDateTime IS NULL
                AND i.InterventionCompleteDateTime IS NULL
                AND i.InterventionInitializeDateTime >= @WindowStart
                AND i.InterventionInitializeDateTime < @WindowEndNextDay
            );

        SELECT @RecordCount = COUNT(*) 
        FROM dbo.tbl_FCAP1A_Procedures_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
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
            'Procedures_Extended',
            @WindowStart,
            @WindowEnd,
            @RecordCount,
            SYSTEM_USER,
            'Extended Procedures build completed.'
        );

    END TRY
    BEGIN CATCH

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'FAILED',
            'Procedures_Extended',
            @WindowStart,
            @WindowEnd,
            SYSTEM_USER,
            ERROR_MESSAGE(),
            'Extended Procedures build failed.'
        );

        THROW;

    END CATCH;

END;
