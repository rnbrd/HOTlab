////////////////////////////////////////////////////////////////////////////////
/*   
   Hologram generating algorithms for CUDA Devices
   
   Copyright 2009, 2010, 2011 Martin Persson 
   martin.persson@physics.gu.se

   This file is part of GenerateHologramCUDA.

   GenerateHologramCUDA is free software: you can redistribute it and/or 
   modify it under the terms of the GNU Lesser General Public License as published 
   by the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   GenerateHologramCUDA is distributed in the hope that it will be 
   useful, but WITHOUT ANY WARRANTY; without even the implied warranty
   of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public License
   along with GenerateHologramCUDA.  If not, see <http://www.gnu.org/licenses/>.
*/
///////////////////////////////////////////////////////////////////////////////////
//The function "GenerateHologram" contains two different algorithms for
//hologram generation. The last parameter in the function call selects which 
//one to use:
//0: Complex addition of "Lenses and Prisms", no optimization (3D)
//1: Weighted Gerchberg-Saxton algorithm using Fresnel propagation (3D)
//2: Weighted Gerchberg-Saxton algorithm using Fast Fourier Transforms (2D)
//-(0) produces optimal holograms for 1 or 2 traps and is significantly faster.
//     (0) is automatically selected if the number of spots is < 3. 
////////////////////////////////////////////////////////////////////////////////
//Fresnel propagation based algorithm (1) described in:
//Roberto Di Leonardo, Francesca Ianni, and Giancarlo Ruocco
//"Computer generation of optimal holograms for optical trap arrays"
//Opt. Express 15, 1913-1922 (2007) 
//
//The original algorithm has been modified to allow variable spot amplitudes
////////////////////////////////////////////////////////////////////////////////
//Naming convention for variables: 
//-The prefix indicates where data is located
//--In host functions:		h = host memory
//							d = device memory
//--In global functions:	g = global memory
//							s = shared memory 
//							no prefix = local memory
//-The suffix indicates the data type
////////////////////////////////////////////////////////////////////////////////
//Possible improvements:
//-Put all arguments for device functions and trap positions in constant memory. 
// (Requires all functions to be moved into the same file or the use of some 
// workaround found on nVidia forum)  	
//-Put pSLMstart and aLaser in texture memory
//-Use "zero-copy" to transfer pSLM to host. (will only work on 1.3 devices and higher)
//-Rename functions and variables for consistency and readability
////////////////////////////////////////////////////////////////////////////////


#include "GenerateHologramCUDA.h"

//////////////////////////////////////////////////
//Global declaration
//////////////////////////////////////////////////
float *d_x, *d_y, *d_z, *d_I;					//trap coordinates and intensity in GPU memory
float *d_pSLM_f;								//the optimized phase pattern, float [-pi, pi]
float *d_weights, *d_weights_start, *d_amps;	//used h_weights and calculated amplitudes for each spot and each iteration
float *d_pSLMstart_f;							//Initial phase pattern [-pi, pi]
float *d_spotRe_f, *d_spotIm_f;
float *d_AberrationCorr_f = NULL; 
float *d_LUTPolCoeff_f = NULL;
int N_LUTPolCoeff = 0;
int n_blocks_Phi, memsize_SLMf, memsize_SLMuc, memsize_spotsf, data_w, N_pixels, N_iterations_last;

unsigned char *d_pSLM_uc;						//The optimized phase pattern, unsigned char, the one sent to the SLM [0, 255]
unsigned char *h_LUT_uc;
unsigned char *d_LUT_uc = NULL;
int maxThreads_device;
bool ApplyLUT_b = false, EnableSLM_b = false, UseAberrationCorr_b = false, UseLUTPol_b = false;

char CUDAmessage[100];
cudaError_t status;

////////////////////////////////////////////////////
//Global declarations for the FFT version
////////////////////////////////////////////////////
float *d_aLaserFFT, *d_LUT_coeff;
cufftHandle plan;
cufftComplex *d_FFTo_cc, *d_FFTd_cc, *d_SLM_cc;
int *d_spot_index, memsize_SLMcc;

////////////////////////////////////////////////////////////////////////////////
// Functions to talk to SLM Hardware
////////////////////////////////////////////////////////////////////////////////
extern "C" int InitalizeSLM(	//returns 0 if PCIe hardware is used, 1 if PCI hardware is used
	bool bRAMWriteEnable, char* LUTFile, unsigned char* LUT, unsigned short TrueFrames
);

extern "C" void LoadImg(
	unsigned char* Img
);

extern "C" void Wait(
	int DelayMs
);

extern "C" void SetPower(
	bool bPower
);

extern "C" void ShutDownSLM();


////////////////////////////////////////////////////////////////////////////////
//The main function, generates a hologram 
////////////////////////////////////////////////////////////////////////////////

extern "C" __declspec(dllexport) int GenerateHologram(float *h_test, unsigned char *h_pSLM_uc, float *x_spots, float *y_spots, float *z_spots, float *I_spots, int N_spots, int N_iterations, float *h_weights, float alpha, int method)
{
	float alpha_RPC = alpha*2.0f*M_PI;
	if (N_spots > BLOCK_SIZE)
	{
		N_spots = BLOCK_SIZE;
	}
	else if (N_spots < 3)
		method = 0;
	
	memsize_spotsf = N_spots*sizeof(float);
	cudaMemcpy(d_x, x_spots, memsize_spotsf, cudaMemcpyHostToDevice);	
	cudaMemcpy(d_y, y_spots, memsize_spotsf, cudaMemcpyHostToDevice);	
	cudaMemcpy(d_z, z_spots, memsize_spotsf, cudaMemcpyHostToDevice);
	cudaMemcpy(d_I, I_spots, memsize_spotsf, cudaMemcpyHostToDevice);

	switch (method)	{
		case 0:
			//////////////////////////////////////////////////
			//Generate the hologram using "Lenses and Prisms"
			//////////////////////////////////////////////////
			LensesAndPrisms<<< n_blocks_Phi, BLOCK_SIZE >>>(d_x, d_y, d_z, d_I, d_pSLM_uc, N_spots, d_LUT_uc, ApplyLUT_b, data_w, UseAberrationCorr_b, d_AberrationCorr_f, UseLUTPol_b, d_LUTPolCoeff_f, N_LUTPolCoeff);
			cudaDeviceSynchronize();
			checkAmplitudes<<< N_spots, 512>>>(d_x, d_y, d_z, d_pSLM_uc, d_amps, N_spots, N_pixels, data_w);
			cudaDeviceSynchronize();
			cudaMemcpy(h_pSLM_uc, d_pSLM_uc, memsize_SLMuc, cudaMemcpyDeviceToHost);	
			cudaMemcpy(h_weights, d_amps, N_spots*sizeof(float), cudaMemcpyDeviceToHost);
			break;
		case 1:
			////////////////////////////////////////////////////
			//Genreate holgram using fresnel propagation
			////////////////////////////////////////////////////
			
			cudaMemcpy(d_weights, d_weights_start, memsize_spotsf, cudaMemcpyDeviceToDevice);
			cudaMemcpy(d_pSLMstart_f, d_pSLM_f, memsize_SLMf, cudaMemcpyDeviceToDevice);
			
			cudaDeviceSynchronize();
			for (int l=0; l<N_iterations; l++)
			{	
				////////////////////////////////////////////////////
				//Propagate to the farfield 
				////////////////////////////////////////////////////				
				PropagateToSpotPositions_Fresnel<<< N_spots, 512>>>(d_x, d_y, d_z, d_pSLM_f, d_spotRe_f, d_spotIm_f, N_spots, N_pixels, data_w);
				cudaDeviceSynchronize();		
				////////////////////////////////////////////////////
				//Propagate to the SLM plane
				////////////////////////////////////////////////////
				PropagateToSLM_Fresnel<<< 512, 512 >>>(d_x, d_y, d_z, d_I, d_spotRe_f, d_spotIm_f, d_pSLM_f, N_pixels, N_spots, d_weights, l, d_pSLMstart_f, alpha_RPC, 
					d_amps, (l==(N_iterations-1)), d_pSLM_uc, d_LUT_uc, ApplyLUT_b, UseAberrationCorr_b, d_AberrationCorr_f, UseLUTPol_b, d_LUTPolCoeff_f, N_LUTPolCoeff);
				cudaDeviceSynchronize();
			}	

			//f2uc<<< n_blocks_Phi, BLOCK_SIZE >>>(d_pSLM_uc, d_pSLM_f, N_pixels, d_LUT_uc, ApplyLUT_b, data_w);
			cudaDeviceSynchronize();
			cudaMemcpy(h_pSLM_uc, d_pSLM_uc, memsize_SLMuc, cudaMemcpyDeviceToHost);			
			cudaMemcpy(h_weights, d_amps, N_spots*(N_iterations)*sizeof(float), cudaMemcpyDeviceToHost);
			//cudaMemcpy(h_weights, d_weights, N_spots*sizeof(float), cudaMemcpyDeviceToHost);
			break;
		case 2: 
			////////////////////////////////////////////////////
			//generate hologram using fast fourier transforms 
			////////////////////////////////////////////////////
			//cudaMemcpy(d_pSLM_uc, h_pSLM_uc, memsize_SLMuc, cudaMemcpyHostToDevice);
			//cudaDeviceSynchronize();
			//p_uc2c_cc_shift<<< n_blocks_Phi, BLOCK_SIZE >>>(d_SLM_cc, d_pSLM_uc, N_pixels, data_w);

			float amp_desired = N_pixels * sqrt(1.0f/(float)N_spots);
			float weight = 1.0f/(float)N_spots;
			for (int i=0; i < N_spots; ++i)
			{
				h_weights[i] = weight;
			} 
			cudaDeviceSynchronize();		
			cudaMemcpy(d_weights, h_weights, N_spots * sizeof(float), cudaMemcpyHostToDevice);
			cudaDeviceSynchronize();
			cudaMemset(d_FFTd_cc, 0, memsize_SLMcc);
			cudaDeviceSynchronize();		
			XYtoIndex <<< 1, N_spots >>>(d_x,  d_y, d_spot_index, N_spots, data_w);
			cudaDeviceSynchronize();		
			for (int l=0; l<N_iterations; l++)
			{
				// Transform to trapping plane
				cufftExecC2C(plan, d_SLM_cc, d_FFTo_cc, CUFFT_FORWARD);
				cudaDeviceSynchronize();

				// Copy phases for spot indices in d_FFTo_cc to d_FFTd_cc
				ReplaceAmpsSpots_FFT <<< 1, N_spots >>> (d_FFTo_cc, d_FFTd_cc, d_spot_index, N_spots, l, d_amps, d_weights, amp_desired);
				cudaDeviceSynchronize();
					//Transform back to SLM plane
				cufftExecC2C(plan, d_FFTd_cc, d_SLM_cc, CUFFT_INVERSE);
				cudaDeviceSynchronize();

				// Set amplitudes in d_SLM to the laser amplitude profile
				ReplaceAmpsSLM_FFT <<< n_blocks_Phi, BLOCK_SIZE >>> (d_aLaserFFT, d_SLM_cc, d_pSLMstart_f, N_pixels, alpha_RPC);
				cudaDeviceSynchronize();
			}	
		
			// Calculate phases in the SLM plane   
			getPhases<<< n_blocks_Phi, BLOCK_SIZE >>> (d_pSLM_uc, d_pSLMstart_f, d_SLM_cc, d_LUT_coeff, 0, data_w);	
			cudaMemcpy(h_weights, d_amps, N_spots*(N_iterations)*sizeof(float), cudaMemcpyDeviceToHost);
			cudaDeviceSynchronize();	
			cudaMemcpy(h_pSLM_uc, d_pSLM_uc, memsize_SLMuc, cudaMemcpyDeviceToHost);			
			break;
	//case 3: Apply corrections on h_pSLM_uc (yet to be implemented)
	}

	//load image to the PCIe hardware  SLMstuff
	if(EnableSLM_b)
		LoadImg(h_pSLM_uc);

	//cudaMemcpy(h_test, d_aLaserDFT, memsize_SLMf, cudaMemcpyDeviceToHost);

	//Handle CUDA errors
	status = cudaGetLastError();
	if(status)
	{
		strcat(CUDAmessage, "CUDA says: ");
		strcat(CUDAmessage,	cudaGetErrorString(status));
		strcat(CUDAmessage,	" in function 'GenerateHologram'\n");
		AfxMessageBox(CUDAmessage);
	}
	return status;
}
__global__ void testfunc(float *testdata)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	testdata[idx] = idx;
}
////////////////////////////////////////////////////////////////////////////////
//Set correction parameters
////////////////////////////////////////////////////////////////////////////////
extern "C" __declspec(dllexport) int Corrections(int UseAberrationCorr, float *h_AberrationCorr, int ApplyLUT, int UseLUTPol, int PolOrder, float *h_LUTPolCoeff)
{
	UseAberrationCorr_b = (bool)UseAberrationCorr;
	ApplyLUT_b = (bool)ApplyLUT;
	UseLUTPol_b = (bool)UseLUTPol;
	int Ncoeff[5] = {20, 35, 56, 84, 120};
	if (3<=PolOrder&&PolOrder<=7)
		N_LUTPolCoeff = Ncoeff[PolOrder - 3];
	else
		UseLUTPol_b = false;

	if(UseAberrationCorr_b)
	{
		if (d_AberrationCorr_f == NULL)		//Allocate memory only if not already allocated
			cudaMalloc((void**)&d_AberrationCorr_f, memsize_SLMf);
		UseAberrationCorr_b = !cudaMemcpy(d_AberrationCorr_f, h_AberrationCorr, memsize_SLMf, cudaMemcpyHostToDevice);
	}
	else if (d_AberrationCorr_f != NULL)	//If memory is allocated: free memory and reset pointer to NULL
	{	
		cudaFree(d_AberrationCorr_f); 
		d_AberrationCorr_f = NULL;
	}
	if(UseLUTPol_b)
	{
		if (d_LUTPolCoeff_f == NULL)		      //Allocate memory only if not already allocated
			cudaMalloc((void**)&d_LUTPolCoeff_f, 120*sizeof(float));
		UseLUTPol_b = !cudaMemcpy(d_LUTPolCoeff_f, h_LUTPolCoeff, N_LUTPolCoeff*sizeof(float), cudaMemcpyHostToDevice);
	}
	else if (d_LUTPolCoeff_f!=NULL)	//If memory is allocated: free memory and reset pointer to NULL
	{
		cudaFree(d_LUTPolCoeff_f);	
		d_LUTPolCoeff_f = NULL;	
	}
	
	//Handle CUDA errors
	status = cudaGetLastError();
	if(status)
	{
		strcat(CUDAmessage, "CUDA says: ");
		strcat(CUDAmessage,	cudaGetErrorString(status));
		strcat(CUDAmessage,	" in function 'Corrections'\n");
		AfxMessageBox(CUDAmessage);
	}
	return status;
}

////////////////////////////////////////////////////////////////////////////////
//Allocate GPU memory and start up SLM
////////////////////////////////////////////////////////////////////////////////
extern "C" __declspec(dllexport) int startCUDAandSLM(int EnableSLM, float *test, char* LUTFile, unsigned short TrueFrames, int deviceId)
{
	cudaSetDevice(deviceId); 
	cudaDeviceProp deviceProp;
    cudaGetDeviceProperties(&deviceProp, deviceId);
    maxThreads_device = deviceProp.maxThreadsPerBlock;
    
	int MaxIterations = 1000;
	int MaxSpots = BLOCK_SIZE;
	data_w = SLM_SIZE;
	N_pixels = data_w * data_w;
	N_iterations_last = 10;
	memsize_spotsf = BLOCK_SIZE * sizeof(float);
	memsize_SLMf = N_pixels * sizeof(float);  
    memsize_SLMuc = N_pixels * sizeof(unsigned char);
	memsize_SLMcc = N_pixels * sizeof(cufftComplex);
    n_blocks_Phi = (N_pixels/BLOCK_SIZE + (N_pixels%BLOCK_SIZE == 0 ? 0:1));

	float h_weights[10000];
	for (int i=0; i < BLOCK_SIZE; ++i)
	{
		h_weights[i] = 1;;
	} 
	//memory allocations for all methods
	cudaMalloc((void**)&d_x, memsize_spotsf );
	cudaMalloc((void**)&d_y, memsize_spotsf );
	cudaMalloc((void**)&d_z, memsize_spotsf );
	cudaMalloc((void**)&d_I, memsize_spotsf );
	cudaMalloc((void**)&d_weights, BLOCK_SIZE*(MaxIterations+1)*sizeof(float));
	cudaMalloc((void**)&d_amps, BLOCK_SIZE*MaxIterations*sizeof(float));
	
	cudaMalloc((void**)&d_spotRe_f, memsize_spotsf );
	cudaMalloc((void**)&d_spotIm_f, memsize_spotsf );
	cudaMalloc((void**)&d_pSLM_f, memsize_SLMf);
	cudaMalloc((void**)&d_pSLMstart_f, memsize_SLMf);
	cudaMalloc((void**)&d_pSLM_uc, memsize_SLMuc);
	cudaMemset(d_pSLM_f, 0, N_pixels*sizeof(float)); 
	
	cudaMalloc((void**)&d_spot_index, BLOCK_SIZE * sizeof(int));
	cudaMalloc((void**)&d_FFTd_cc, memsize_SLMcc);	
	cudaMalloc((void**)&d_FFTo_cc, memsize_SLMcc);
	cudaMalloc((void**)&d_SLM_cc, memsize_SLMcc);
	cufftPlan2d(&plan, data_w, data_w, CUFFT_C2C);
	
	cudaMalloc((void**)&d_weights_start, MaxSpots*sizeof(float));
	//cudaMemset(d_weights_start, 1.0f, MaxSpots*sizeof(float));
	cudaMemcpy(d_weights_start, h_weights, MaxSpots*sizeof(float), cudaMemcpyHostToDevice);
	float *h_aLaserFFT = (float *)malloc(memsize_SLMf);

	//Open up communication to the PCIe hardware
	EnableSLM_b = EnableSLM; //SLMstuff
	if(EnableSLM_b)
	{
		bool bRAMWriteEnable = false;
		h_LUT_uc = new unsigned char[256];
		ApplyLUT_b = (bool)InitalizeSLM(bRAMWriteEnable, LUTFile, h_LUT_uc, TrueFrames);  //InitalizeSLM returns 1 if PCI version is installed, PCIe version returns 0 since it applies LUT in hardware 
		cudaMalloc((void**)&d_LUT_uc, 256);
		cudaMemcpy(d_LUT_uc, h_LUT_uc, 256, cudaMemcpyHostToDevice);
		delete []h_LUT_uc;
		SetPower(true);
	}	
	else
	{
		ApplyLUT_b = false;
	}
	
	//Display CUDA errors
	status = cudaGetLastError();
	if(status)
	{
		strcat(CUDAmessage, "CUDA says: ");
		strcat(CUDAmessage,	cudaGetErrorString(status));
		strcat(CUDAmessage,	" in function 'startCUDAandSLM'\n");
		AfxMessageBox(CUDAmessage);
	}
	return status;
}

extern "C" __declspec(dllexport) int stopCUDAandSLM()
{
	cudaFree(d_x);
	cudaFree(d_y);
	cudaFree(d_z);
	cudaFree(d_I);

	cudaFree(d_weights);
	cudaFree(d_amps);
	cudaFree(d_pSLM_f);
	cudaFree(d_pSLMstart_f);
	cudaFree(d_pSLM_uc);
	
	cudaFree(d_FFTd_cc);
	cudaFree(d_FFTo_cc);
	cudaFree(d_SLM_cc);
	cufftDestroy(plan);
		
	if (ApplyLUT_b)
	{	
		cudaFree(d_LUT_uc); 
		d_LUT_uc = NULL;
	}
	
	if (UseAberrationCorr_b)
	{
		cudaFree(d_AberrationCorr_f); 
		d_AberrationCorr_f = NULL;
	}
	
	if (UseLUTPol_b)
	{	
		cudaFree(d_LUTPolCoeff_f); 
		d_LUTPolCoeff_f = NULL;
	}

	status = cudaGetLastError();
	if(status)
	{
		
		strcat(CUDAmessage, "CUDA says: ");
		strcat(CUDAmessage,	cudaGetErrorString(status));
		strcat(CUDAmessage,	" in function 'stopCUDAandSLM'\n");
		AfxMessageBox(CUDAmessage);
	}

	cudaDeviceReset();
	
	//close out communication with the PCIe hardware SLMstuff
	if(EnableSLM_b)
		ShutDownSLM();

	return status;
}
////////////////////////////////////////////////////////////////////////////////
//Calculate amplitudes in positions given by x, y, and z from a given hologram
////////////////////////////////////////////////////////////////////////////////
extern "C" __declspec(dllexport) int GetAmps(float *x_spots, float *y_spots, float *z_spots, float *h_pSLM_uc, int N_spots_all, int data_w, float *h_amps)
{
	float *d_xall, *d_yall, *d_zall, *d_amps_all;
	cudaMalloc((void**)&d_xall, N_spots_all*sizeof(float) );
	cudaMalloc((void**)&d_yall, N_spots_all*sizeof(float) );
	cudaMalloc((void**)&d_zall, N_spots_all*sizeof(float) );
	cudaMalloc((void**)&d_amps_all, N_spots_all*sizeof(float) );
	cudaMemcpy(d_xall, x_spots, N_spots_all*sizeof(float), cudaMemcpyHostToDevice);	
	cudaMemcpy(d_yall, y_spots, N_spots_all*sizeof(float), cudaMemcpyHostToDevice);	
	cudaMemcpy(d_zall, z_spots, N_spots_all*sizeof(float), cudaMemcpyHostToDevice);
	
	int N_pixels = data_w*data_w;
	cudaMemcpy(d_pSLM_uc, h_pSLM_uc, memsize_SLMuc, cudaMemcpyHostToDevice);
	int offset = 0;
	bool spots_left = true;
	int N_spots_rem = N_spots_all;
	while (N_spots_rem > 0)
	{
		int N_spots = (N_spots_rem > 512) ? 512 : N_spots_rem;
		memsize_spotsf = N_spots*sizeof(float);
		checkAmplitudes<<< N_spots, 512>>>(d_xall+offset, d_yall+offset, d_zall+offset, d_pSLM_uc, d_amps_all+offset, N_spots, N_pixels, data_w);
		cudaDeviceSynchronize();
		
		N_spots_rem -= 512;
		offset += 512;
	}
	cudaMemcpy(h_amps, d_amps_all, N_spots_all*sizeof(float), cudaMemcpyDeviceToHost);
	
	cudaFree(d_xall);
	cudaFree(d_yall);
	cudaFree(d_zall);
	cudaFree(d_amps_all);
	
	status = cudaGetLastError();
	if(status)
	{
		strcat(CUDAmessage, "CUDA says: ");
		strcat(CUDAmessage,	cudaGetErrorString(status));
		strcat(CUDAmessage,	" in function 'GetAmps'\n");
		AfxMessageBox(CUDAmessage);
	}
	return status;
}
