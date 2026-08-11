/* Author: test */
﻿USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Immunizations_Extended]    Script Date: 7/13/2026 1:14:58 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* 
   Stored Procedure: usp_Build_FCAP1A_Immunizations_Extended
  ---
   Purpose:
     • Build the FCAP 1A Immunizations_Extended dataset for the Extended 10 percent cohort
     • Sources (AKULivendb via NBIDRSRV):
         [NBIDRSRV2].[AKULivendb].dbo.AdmVisits
         [NBIDRSRV2].[AKULivendb].dbo.PhaRxImmunizationData
         [NBIDRSRV2].[AKULivendb].dbo.PhaRxImmunizationDataMore
         [NBIDRSRV2].[AKULivendb].dbo.PhaRxAdminImmunizations
         [NBIDRSRV2].[AKULivendb].dbo.PhaRxAdminImmunMultiDoseLots
         [NBIDRSRV2].[AKULivendb].dbo.PhaRxAdminImmunizationCmtsText
         [NBIDRSRV2].[AKULivendb].dbo.DPhaDrugData
     • Logs execution details to dbo.FCAP1A_Cohort_Log

   Notes:
     • Grain: one row per immunization event (PrescriptionID, SourceID, VisitID)
     • EventDateTime = COALESCE(GivenDateTime, ReadDateTime, RowUpdateDateTime)
     • All joins between CDIO and Meditech use COLLATE SQL_Latin1_General_CP1_CI_AS

   Author      : Allan Zablon
   Date        : 2026-02-23
   Revised     : 2026 -07-13
   Version     : Extended
*/

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_Immunizations_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart         DATETIME = SYSDATETIME(),
        @RunEnd           DATETIME,
        @DurationSeconds  INT,
        @RecordCount      INT = 0,
        @TotalEligible    INT = 0,
        @WindowStart      DATE = '2022-11-05',
        @WindowEnd        DATE = '2026-06-14',
        @WindowEndNextDay DATE = DATEADD(DAY,1,'2026-06-14');

    IF OBJECT_ID('dbo.tbl_FCAP1A_Immunizations_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_Immunizations_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_Immunizations_Extended (
        ImmunizationRowID INT IDENTITY(1,1) PRIMARY KEY,
        PatientID NVARCHAR(50) NOT NULL,
        VisitID NVARCHAR(50) NULL,
        SourceID VARCHAR(3) NOT NULL,
        PrescriptionID NVARCHAR(255) NOT NULL,
        DrugID NVARCHAR(255) NULL,
        VaccineID NVARCHAR(255) NULL,
        VaccineName NVARCHAR(255) NULL,
        VaccineGroup NVARCHAR(255) NULL,
        Strength NVARCHAR(255) NULL,
        StrengthAmount1 DECIMAL(18,7) NULL,
        StrengthAmount2 DECIMAL(18,7) NULL,
        DictionaryOrderUnitID NVARCHAR(255) NULL,
        AdminFormID NVARCHAR(255) NULL,
        DispenseFormID NVARCHAR(255) NULL,
        NdcDinNumber NVARCHAR(255) NULL,
        Given NVARCHAR(255) NULL,
        GivenDateTime DATETIME NULL,
        ReadDateTime DATETIME NULL,
        EventDateTime DATETIME NOT NULL,
        IncludeInHistory NVARCHAR(255) NULL,
        InformedConsent NVARCHAR(255) NULL,
        Reason NVARCHAR(255) NULL,
        ReasonNotGivenID NVARCHAR(255) NULL,
        RegionalReasonID NVARCHAR(255) NULL,
        VarianceReasonID NVARCHAR(255) NULL,
        EligibilityStatus NVARCHAR(255) NULL,
        EligibilityDateTime DATETIME NULL,
        FundingSourceID NVARCHAR(255) NULL,
        VaccineFundingSourceID NVARCHAR(255) NULL,
        Paid NVARCHAR(255) NULL,
        Amount MONEY NULL,
        EventOrderUnitID NVARCHAR(255) NULL,
        NewDoseCount INT NULL,
        OldDoseCount INT NULL,
        LotNumber NVARCHAR(255) NULL,
        ManufacturerID NVARCHAR(255) NULL,
        ManufactureFree NVARCHAR(255) NULL,
        ServiceLocation NVARCHAR(255) NULL,
        DeliveryMgmtSiteID NVARCHAR(255) NULL,
        DeliveryMgmtSiteMnemonicID NVARCHAR(255) NULL,
        SiteID NVARCHAR(255) NULL,
        InjectionSite NVARCHAR(255) NULL,
        InjectionAdminSiteID NVARCHAR(255) NULL,
        Reaction NVARCHAR(255) NULL,
        VisGivenDateTime DATETIME NULL,
        VisPubDateTime DATETIME NULL,
        VirusInfoGivenDateTime DATETIME NULL,
        VirusInfoPublicationDateTime DATETIME NULL,
        AdminUserID NVARCHAR(255) NULL,
        ReadUserID NVARCHAR(255) NULL,
        MultiDoseLotDoseSummary NVARCHAR(2000) NULL,
        RowUpdateDateTime DATETIME NULL,
        ExtractedFrom NVARCHAR(200) NULL,
        ExtractedOn DATETIME NOT NULL DEFAULT SYSDATETIME()
    );

    SELECT @TotalEligible = COUNT(*) 
    FROM dbo.tbl_FCAP1A_Cohort10_Extended;

    ;WITH BaseImmunizations AS (
        SELECT
            c.PatientID,
            v.VisitID,
            i.SourceID,
            i.PrescriptionID,
            i.DrugID,
            i.VaccineID,
            i.Given,
            i.GivenDateTime,
            i.ReadDateTime,
            COALESCE(i.GivenDateTime,i.ReadDateTime,i.RowUpdateDateTime) AS EventDateTime,
            i.IncludeInHistory,
            i.InformedConsent,
            i.LotNumber,
            i.ManufacturerID,
            i.NewDoseCount,
            i.OldDoseCount,
            i.OrderUnitID,
            i.Paid,
            i.Reaction,
            i.Reason,
            i.ReasonNotGivenID,
            i.RegionalReasonID,
            i.ServiceLocation,
            i.SiteID,
            i.VarianceReasonID,
            i.AdminUserID,
            i.ReadUserID,
            i.Amount,
            i.DeliveryMgmtSiteID,
            i.RowUpdateDateTime
        FROM dbo.tbl_FCAP1A_Cohort10_Extended c
        INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits v
            ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
               v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
        INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.PhaRxImmunizationData i
            ON v.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS =
               i.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
        WHERE COALESCE(i.GivenDateTime,i.ReadDateTime,i.RowUpdateDateTime) >= @WindowStart
          AND COALESCE(i.GivenDateTime,i.ReadDateTime,i.RowUpdateDateTime) < @WindowEndNextDay
    )

    INSERT INTO dbo.tbl_FCAP1A_Immunizations_Extended (
        PatientID, VisitID, SourceID, PrescriptionID, DrugID, VaccineID,
        VaccineName, VaccineGroup, Strength, StrengthAmount1, StrengthAmount2,
        DictionaryOrderUnitID, AdminFormID, DispenseFormID, NdcDinNumber,
        Given, GivenDateTime, ReadDateTime, EventDateTime,
        IncludeInHistory, InformedConsent, Reason, ReasonNotGivenID,
        RegionalReasonID, VarianceReasonID,
        EligibilityStatus, EligibilityDateTime, FundingSourceID, VaccineFundingSourceID,
        Paid, Amount, EventOrderUnitID, NewDoseCount, OldDoseCount,
        LotNumber, ManufacturerID, ManufactureFree,
        ServiceLocation, DeliveryMgmtSiteID, DeliveryMgmtSiteMnemonicID,
        SiteID, InjectionSite, InjectionAdminSiteID,
        Reaction,
        VisGivenDateTime, VisPubDateTime,
        VirusInfoGivenDateTime, VirusInfoPublicationDateTime,
        AdminUserID, ReadUserID,
        MultiDoseLotDoseSummary,
        RowUpdateDateTime, ExtractedFrom
    )
    SELECT DISTINCT
        b.PatientID, b.VisitID, b.SourceID, b.PrescriptionID, b.DrugID, b.VaccineID,
        d.Name, d.Vaccine, d.Strength, d.StrengthAmount1, d.StrengthAmount2,
        d.OrderUnitID, d.AdminFormID, d.DispenseFormID, d.NdcDinNumber,
        b.Given, b.GivenDateTime, b.ReadDateTime, b.EventDateTime,
        b.IncludeInHistory, b.InformedConsent, b.Reason, b.ReasonNotGivenID,
        b.RegionalReasonID, b.VarianceReasonID,
        NULL, NULL, NULL, NULL,
        b.Paid, b.Amount, b.OrderUnitID, b.NewDoseCount, b.OldDoseCount,
        b.LotNumber, b.ManufacturerID, NULL,
        b.ServiceLocation, b.DeliveryMgmtSiteID, NULL,
        b.SiteID, NULL, NULL,
        b.Reaction,
        NULL, NULL,
        NULL, NULL,
        b.AdminUserID, b.ReadUserID,
        NULL,
        b.RowUpdateDateTime,
        N'Immunizations_Extended'
    FROM BaseImmunizations b
    LEFT JOIN [NBIDRSRV2].[AKULivendb].dbo.DPhaDrugData d
        ON b.SourceID = d.SourceID
       AND b.DrugID COLLATE SQL_Latin1_General_CP1_CI_AS =
           d.DrugID COLLATE SQL_Latin1_General_CP1_CI_AS;

    SELECT @RecordCount = COUNT(*) FROM dbo.tbl_FCAP1A_Immunizations_Extended;

    SET @RunEnd = SYSDATETIME();
    SET @DurationSeconds = DATEDIFF(SECOND,@RunStart,@RunEnd);

    INSERT INTO dbo.FCAP1A_Cohort_Log (
        RunStart, RunEnd, DurationSeconds, RunStatus,
        DataTopic, WindowStart, WindowEnd,
        TotalEligible, RecordCount, ProcessedBy, ErrorMessage, Remarks
    )
    VALUES (
        @RunStart, @RunEnd, @DurationSeconds, 'SUCCESS',
        N'Immunizations_Extended', @WindowStart, @WindowEnd,
        @TotalEligible, @RecordCount, SYSTEM_USER, NULL,
        N'Extended immunizations rebuild completed successfully.'
    );

END
