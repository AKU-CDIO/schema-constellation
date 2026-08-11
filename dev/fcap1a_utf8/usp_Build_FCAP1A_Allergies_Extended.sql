/* Author: test */
﻿USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Allergies_Extended]    Script Date: 2/19/2026 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_Build_FCAP1A_Allergies_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart        DATETIME = SYSDATETIME(),
        @RunEnd          DATETIME,
        @DurationSeconds INT,
        @RecordCount     INT = 0;

    /*
        Procedure: usp_Build_FCAP1A_Allergies_Extended
        Purpose:
            Build a lifetime allergy dataset for the FCAP 1A Cohort with:

                - Internal EMR allergies
                - External/CCD allergies
                - Immunization ADR allergies
                - Full lifetime coverage (no date window filter)
                - Clear clinical date field (AllergyDocumentedDateTime)
                - RowUpdateDateTime kept separate (SCD2)
                - Multiline and single-line allergy comments
                - Dictionary enrichment from DMisAllergies

        Author  : Allan Z
        Development Date : 2026-02-19
    */

    IF OBJECT_ID('dbo.tbl_FCAP1A_Allergies_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_Allergies_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_Allergies_Extended (
        AllergyID                BIGINT IDENTITY(1,1) PRIMARY KEY,

        PatientID                NVARCHAR(50)   NOT NULL,
        AllergySourceType        NVARCHAR(30)   NOT NULL,

        InternalAllergenID       NVARCHAR(200)  NULL,
        ExternalAllergenID       NVARCHAR(200)  NULL,
        AllergenGroupID          NVARCHAR(75)   NULL,

        AllergenName             NVARCHAR(250)  NULL,
        AllergenCategory         NVARCHAR(50)   NULL,

        Reaction                 NVARCHAR(250)  NULL,
        Severity                 NVARCHAR(50)   NULL,
        Status                   NVARCHAR(20)   NULL,

        AllergyDocumentedDateTime DATETIME      NULL,
        VerifyDateTime           DATETIME       NULL,
        EndDateTime              DATETIME       NULL,

        DocumentSourceID         NVARCHAR(125)  NULL,
        DocumentIdentifierID     NVARCHAR(150)  NULL,
        DocumentDateTime         DATETIME       NULL,

        AllergyText              NVARCHAR(MAX)  NULL,
        AllergyCommentText       NVARCHAR(MAX)  NULL,

        RowUpdateDateTime        DATETIME       NULL,
        ExtractedFrom            NVARCHAR(200)  NOT NULL,
        ExtractedOn              DATETIME       NOT NULL DEFAULT SYSDATETIME()
    );

    BEGIN TRY

        ;WITH

        Internal_Allergies_Raw AS (
            SELECT
                ea.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS AS PatientID,
                ea.AllergenID COLLATE SQL_Latin1_General_CP1_CI_AS AS AllergenID,
                CAST('INTERNAL' AS NVARCHAR(30)) AS AllergySourceType,

                ea.AllergySeverity,
                ea.AllergyReaction,
                ea.AllergyStatus,

                COALESCE(
                    ea.AllergyDateTime,
                    ea.AllergyVerifyDateTime,
                    ea.AllergyInitializeDateTime,
                    ea.RowUpdateDateTime
                ) AS AllergyDocumentedDateTime,

                ea.AllergyVerifyDateTime AS VerifyDateTime,
                ea.RowUpdateDateTime
            FROM dbo.tbl_FCAP1A_Cohort10_Extended c
            JOIN [NBIDRSRV].[AKULiveATdb].dbo.EmrPat_Allergies ea
              ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                 ea.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
        ),

        Internal_Allergies_Dedup AS (
            SELECT *,
                   ROW_NUMBER() OVER (
                       PARTITION BY PatientID, AllergenID
                       ORDER BY RowUpdateDateTime DESC
                   ) AS rn
            FROM Internal_Allergies_Raw
        ),

        Internal_Allergies AS (
            SELECT
                PatientID,
                AllergenID,
                AllergySourceType,
                AllergySeverity,
                AllergyReaction,
                AllergyStatus,
                AllergyDocumentedDateTime,
                VerifyDateTime,
                RowUpdateDateTime
            FROM Internal_Allergies_Dedup
            WHERE rn = 1
        ),

        Internal_AllergyComments AS (
            SELECT
                ac.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS AS PatientID,
                ac.AllergenID COLLATE SQL_Latin1_General_CP1_CI_AS AS AllergenID,

                STRING_AGG(
                    CAST(ac.TextLine AS NVARCHAR(MAX)),
                    CHAR(10)
                ) WITHIN GROUP (ORDER BY ac.TextSeqID) AS AllergyText_Multiline,

                STRING_AGG(
                    CAST(ac.TextLine AS NVARCHAR(MAX)),
                    N' '
                ) WITHIN GROUP (ORDER BY ac.TextSeqID) AS AllergyText_SingleLine
            FROM [NBIDRSRV].[AKULiveATdb].dbo.EmrPat_Allergies_AllrgComment ac
            GROUP BY
                ac.PatientID,
                ac.AllergenID
        ),

        Internal_Allergies_Final AS (
            SELECT
                ia.PatientID,
                ia.AllergySourceType,
                ia.AllergenID AS InternalAllergenID,
                NULL AS ExternalAllergenID,
                NULL AS AllergenGroupID,

                d.Name     AS AllergenName,
                d.Category AS AllergenCategory,

                ia.AllergyReaction AS Reaction,
                ia.AllergySeverity AS Severity,
                ia.AllergyStatus   AS Status,

                ia.AllergyDocumentedDateTime,
                ia.VerifyDateTime,
                NULL AS EndDateTime,

                NULL AS DocumentSourceID,
                NULL AS DocumentIdentifierID,
                NULL AS DocumentDateTime,

                ic.AllergyText_Multiline AS AllergyText,
                ic.AllergyText_SingleLine AS AllergyCommentText,

                ia.RowUpdateDateTime,
                N'EmrPat_Allergies;AllrgComment;DMisAllergies' AS ExtractedFrom
            FROM Internal_Allergies ia
            LEFT JOIN Internal_AllergyComments ic
                ON ia.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   ic.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND ia.AllergenID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   ic.AllergenID COLLATE SQL_Latin1_General_CP1_CI_AS
            LEFT JOIN [NBIDRSRV].[AKULivendb].dbo.DMisAllergies d
                ON ia.AllergenID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   d.AllergyID COLLATE SQL_Latin1_General_CP1_CI_AS
        ),

        External_Allergies_Raw AS (
            SELECT
                ea.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS AS PatientID,
                ea.ExternalAllergenID COLLATE SQL_Latin1_General_CP1_CI_AS AS ExternalAllergenID,
                ea.ExternalAllergyDocumentSourceID COLLATE SQL_Latin1_General_CP1_CI_AS AS ExternalAllergyDocumentSourceID,
                ea.ExternalAllergyDocumentIdentifierID COLLATE SQL_Latin1_General_CP1_CI_AS AS ExternalAllergyDocumentIdentifierID,
                CAST('EXTERNAL' AS NVARCHAR(30)) AS AllergySourceType,

                ea.ExternalSeverity,
                ea.ExternalReaction,
                ea.ExternalStatus,

                COALESCE(ea.ExternalStartDate, ea.RowUpdateDateTime)
                    AS AllergyDocumentedDateTime,

                ea.RowUpdateDateTime,
                ea.ExternalEndDate
            FROM dbo.tbl_FCAP1A_Cohort10_Extended c
            JOIN [NBIDRSRV].[AKULiveATdb].dbo.EmrPat_ExtAllergies ea
              ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                 ea.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
        ),

        External_Allergies_Dedup AS (
            SELECT *,
                   ROW_NUMBER() OVER (
                       PARTITION BY PatientID,
                                    ExternalAllergenID,
                                    ExternalAllergyDocumentIdentifierID
                       ORDER BY RowUpdateDateTime DESC
                   ) AS rn
            FROM External_Allergies_Raw
        ),

        External_Allergies_Final AS (
            SELECT
                e.PatientID,
                e.AllergySourceType,
                NULL AS InternalAllergenID,
                e.ExternalAllergenID,
                NULL AS AllergenGroupID,

                NULL AS AllergenName,
                NULL AS AllergenCategory,

                e.ExternalReaction AS Reaction,
                e.ExternalSeverity AS Severity,
                e.ExternalStatus   AS Status,

                e.AllergyDocumentedDateTime AS AllergyDocumentedDateTime,
                NULL AS VerifyDateTime,
                e.ExternalEndDate AS EndDateTime,

                e.ExternalAllergyDocumentSourceID AS DocumentSourceID,
                e.ExternalAllergyDocumentIdentifierID AS DocumentIdentifierID,
                NULL AS DocumentDateTime,

                NULL AS AllergyText,
                NULL AS AllergyCommentText,

                e.RowUpdateDateTime,
                N'EmrPat_ExtAllergies' AS ExtractedFrom
            FROM External_Allergies_Dedup e
            WHERE e.rn = 1
        ),

        ImmunAdr_Allergies_Raw AS (
            SELECT
                ia.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS AS PatientID,
                ia.ImmunizationAdrAllergyNameID COLLATE SQL_Latin1_General_CP1_CI_AS AS ImmunizationAdrAllergyNameID,
                ia.ImmunizationAdrDataSourceID COLLATE SQL_Latin1_General_CP1_CI_AS AS ImmunizationAdrDataSourceID,
                ia.ImmunizationAdrDataUrnID,
                ia.RowUpdateDateTime,
                CAST('IMMUNIZATION' AS NVARCHAR(30)) AS AllergySourceType
            FROM dbo.tbl_FCAP1A_Cohort10_Extended c
            JOIN [NBIDRSRV].[AKULiveATdb].dbo.EmrPat_ImmunAdrAllergies ia
              ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                 ia.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
        ),

        ImmunAdr_Allergies_Dedup AS (
            SELECT *,
                   ROW_NUMBER() OVER (
                       PARTITION BY PatientID, ImmunizationAdrAllergyNameID
                       ORDER BY RowUpdateDateTime DESC
                   ) AS rn
            FROM ImmunAdr_Allergies_Raw
        ),

        ImmunAdr_Allergies_Final AS (
            SELECT
                i.PatientID,
                i.AllergySourceType,
                NULL AS InternalAllergenID,
                i.ImmunizationAdrAllergyNameID AS ExternalAllergenID,
                NULL AS AllergenGroupID,

                NULL AS AllergenName,
                NULL AS AllergenCategory,

                NULL AS Reaction,
                NULL AS Severity,
                NULL AS Status,

                i.RowUpdateDateTime AS AllergyDocumentedDateTime,
                NULL AS VerifyDateTime,
                NULL AS EndDateTime,

                i.ImmunizationAdrDataSourceID AS DocumentSourceID,
                CAST(CAST(i.ImmunizationAdrDataUrnID AS BIGINT) AS NVARCHAR(150)) AS DocumentIdentifierID,
                NULL AS DocumentDateTime,

                NULL AS AllergyText,
                NULL AS AllergyCommentText,

                i.RowUpdateDateTime,
                N'EmrPat_ImmunAdrAllergies' AS ExtractedFrom
            FROM ImmunAdr_Allergies_Dedup i
            WHERE i.rn = 1
        ),

        Allergies_All AS (
            SELECT * FROM Internal_Allergies_Final
            UNION ALL
            SELECT * FROM External_Allergies_Final
            UNION ALL
            SELECT * FROM ImmunAdr_Allergies_Final
        )

        INSERT INTO dbo.tbl_FCAP1A_Allergies_Extended (
            PatientID,
            AllergySourceType,
            InternalAllergenID,
            ExternalAllergenID,
            AllergenGroupID,
            AllergenName,
            AllergenCategory,
            Reaction,
            Severity,
            Status,
            AllergyDocumentedDateTime,
            VerifyDateTime,
            EndDateTime,
            DocumentSourceID,
            DocumentIdentifierID,
            DocumentDateTime,
            AllergyText,
            AllergyCommentText,
            RowUpdateDateTime,
            ExtractedFrom,
            ExtractedOn
        )
        SELECT DISTINCT
            PatientID,
            AllergySourceType,
            InternalAllergenID,
            ExternalAllergenID,
            AllergenGroupID,
            AllergenName,
            AllergenCategory,
            Reaction,
            Severity,
            Status,
            AllergyDocumentedDateTime,
            VerifyDateTime,
            EndDateTime,
            DocumentSourceID,
            DocumentIdentifierID,
            DocumentDateTime,
            AllergyText,
            AllergyCommentText,
            RowUpdateDateTime,
            ExtractedFrom,
            SYSDATETIME()
        FROM Allergies_All;

        SELECT @RecordCount = COUNT(*) FROM dbo.tbl_FCAP1A_Allergies_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            RecordCount,
            ProcessedBy,
            Remarks
        )
        VALUES (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            'Allergies_Extended',
            @RecordCount,
            SYSTEM_USER,
            'Lifetime allergies with comment enrichment and collation-safe joins.'
        );

    END TRY
    BEGIN CATCH

        INSERT INTO dbo.FCAP1A_Cohort_Log (
            RunStart,
            RunEnd,
            RunStatus,
            DataTopic,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES (
            @RunStart,
            SYSDATETIME(),
            'FAILED',
            'Allergies_Extended',
            SYSTEM_USER,
            ERROR_MESSAGE(),
            'Error during Allergies_Extended rebuild.'
        );

        THROW;
    END CATCH;
END;
GO