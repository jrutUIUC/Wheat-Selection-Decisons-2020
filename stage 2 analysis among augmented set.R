setwd("/Users/jrut/Documents/GitHub/Wheat-Selection-Decisons-2020")
library(asreml)
library(arm)

#read in the blues from stage 1
blues<- read.csv('Aug2020blues.csv', row.names=1) 

###exclude data points that are outliers
blues[which(blues$trait=='Grain.yield...bu.ac' & blues$predicted.value>180),'predicted.value']<- NA
blues[which(blues$trait=='Heading.time...Julian.date..JD..' & blues$predicted.value>200),'predicted.value']<- NA
blues[which(blues$trait=='Plant.height...cm.' & blues$predicted.value<15),'predicted.value']<- NA

##Functions to use later
#function to check model convergence and update until converged (tolerate a 1.5% change in components)
mkConv<- function(mod){
  pctchg<- summary(mod)$varcomp[,c('%ch')]
  while(any(pctchg >2, na.rm=TRUE)){
    mod<-suppressWarnings(update(mod))
    pctchg<- summary(mod)$varcomp[,c('%ch')]
  }
  return(mod)
}


#subset yield trials only
blues$germplasmDbId<- as.factor(blues$germplasmDbId)
bluesYld<- droplevels.data.frame(blues[which(blues$studyName %in% c('Aug_Neo_20', 'Aug_Urb_20')),])
colnames(bluesYld)[5]<- "Y"

#add rows for the missing values
a<- cast(bluesYld, names+studyName~trait, value='Y')
b<- cast(bluesYld, names+studyName~trait, value='std.error')
mta<- melt(a)
mtb<- melt(b)

#estimate weights based on the standard error 
wt<- 1/(mtb$value^2)

#set missing weights to zero
wt[which(is.na(wt))]<- 0

#add weight to the dataset
df<- data.frame(mta, wt)

#fit model across locations
mod<- asreml(fixed=value~1+studyName+trait+studyName:trait, random=~us(trait):names, 
  data=df, weights=wt, family = asr_gaussian(dispersion = 1))
mod<- mkConv(mod)

#get the blups + means across locations
p<- predict(mod, classify = 'names:trait', pworkspace=64e6)
blup<- p$pvals

#get the blups + means per location (needed for the traits only measured in Urbana)
p<- predict(mod, classify = 'names:trait:studyName', pworkspace=64e6)
blup2<- p$pvals
blup2<- na.omit(blup2[which(blup2$trait %in% c('Heading.time...Julian.date..JD..', 'Lodging.incidence...0.9.percentage.scale.')),])
blup<- rbind(blup2[,-c(2)], blup)

####estimate blups from the disease nurseries
pheno<- read.csv('All 2018-2020 data as of July 21 2020.csv', as.is=TRUE)

#add column for check
pheno<- data.frame(pheno, check="0", stringsAsFactors = FALSE)
pheno[which(pheno$germplasmName=='07-4415'),'check']<- '1'
pheno[which(pheno$germplasmName=='Kaskaskia'),'check']<- '1'

#add different name columns
nameCheck<-as.character(pheno$germplasmName) 
nameEntry<-as.character(pheno$germplasmName) 
nameCheck[which(pheno$check=="0")]<- "0"
nameEntry[which(pheno$check=="1")]<- "0"
pheno<- data.frame(pheno, nameCheck, nameEntry)

#change factors to factors
pheno$germplasmName<- as.factor(as.character(pheno$germplasmName))
pheno$check<- as.factor(as.character(pheno$check))
pheno$nameCheck<- as.factor(as.character(pheno$nameCheck))
pheno$nameEntry<- as.factor(as.character(pheno$nameEntry))

#fit model for sbmv
modSv<- asreml(fixed= Soil.borne.mosaic.plant.response...0.9.Response.Scale.CO_321.0501140~1+at(check, '1'):nameCheck, 
               random= ~at(check, '0'):nameEntry, 
               data=pheno, subset=pheno$studyName=='Aug_Sbmv_20')
blupsSv<- predict(modSv, 'nameEntry:check', ignore=c('(Intercept)','nameCheck'), levels=list(check='0'))$pvals

#fit model for scb
modScb<- asreml(fixed= FHB.plant.response...1.9.response.scale.CO_321.0501028~1+at(check, '1'):nameCheck, 
                random= ~at(check, '0'):nameEntry, 
                data=pheno, subset=pheno$studyName=='Aug_Scb_20')

#make blup tables
blupsScb<- predict(modScb, 'nameEntry:check', ignore=c('(Intercept)','nameCheck'), levels=list(check='0'))$pvals
sbmv<- blupsSv[,c('nameEntry', 'predicted.value')]
scb<- blupsScb[,c('nameEntry', 'predicted.value')]
colnames(sbmv)<- c('names', 'SBMV')
colnames(scb)<- c('names', 'Scb')


####Make summary table with all blups
wide<- cast(na.omit(blup), names~trait, value='predicted.value')

#subtract the means from the blups
mns<- colMeans(wide[,-1])
for(i in 2:ncol(wide)){
  wide[,i]<- wide[,i]-mns[c(i-1)]
}

#combine yield trial results and disease nursery results
wide<- merge(wide, scb, by='names', all.x=T)
wide<- merge(wide, sbmv, by='names', all.x=T)

#impute missing data with the mean
for(i in 2:ncol(wide)){
  wide[which(is.na(wide[,i])),i]<- mean(wide[,i], na.rm=T)
}

##calculate indies
balancedIX<-wide$Grain.test.weight...lbs.bu * 0.5 +
  wide$Grain.yield...bu.ac * 1 +
  wide$Heading.time...Julian.date..JD.. * -1 +
  wide$Scb* -1  +
  wide$Plant.height...cm. * -1+
  wide$SBMV * -0.25

#add index to summary table
wide<- data.frame(wide, balancedIX)

#check seed amounts where the seed was saved
augUrb<- pheno[which(pheno$studyName=='Aug_Urb_20'),]
aug<- augUrb[,c('observationUnitName', 'germplasmName','Grain.yield...kg.ha.CO_321.0001218')]

#convert back to grams per plot
kgSqm<- aug$Grain.yield...kg.ha.CO_321.0001218/10000
gSqm<- kgSqm*1000
aug[,3]<- gSqm *3.15

#add seed amounts to summary table
colnames(aug)[3]<- 'seedInv.g'
colnames(aug)[2]<- 'names'
aug<- merge(aug, wide)

#order by index value
aug<- aug[order(aug$balancedIX, decreasing=TRUE),]

#remove checks
aug<- aug[-which(aug$names %in% c('07-4415', 'Kaskaskia')),]

#add ranking
aub<- data.frame(aug, ranking=rank(-aug$balancedIX))
write.csv(aug, 'prelimRanking2020.csv')

